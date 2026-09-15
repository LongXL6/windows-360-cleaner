#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ReportDirectory,

    [ValidateSet('Auto', 'Scan', 'Verify')]
    [string]$StartPage = 'Auto',

    [switch]$InternalTestLibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Windows 360 Cleaner - guided window for beginners.
# This window never deletes anything by itself. Checks (scans and verifications) run the core read-only.
# Removal is started only after the user ticked items, passed the selection pre-check and
# explicitly confirmed; the core then re-checks everything after elevation. The window adds no
# automatic deletion, forced deletion, automatic elevation, reboot, autostart, telemetry or upload.
# Main pages speak plain language (delete / keep); technical details live in the More info, Details
# and Get help windows only.

$script:SelectorCoreScriptPath = Join-Path $PSScriptRoot 'Invoke-360Cleanup.ps1'
$script:SelectorLibraryPath = Join-Path $PSScriptRoot 'Windows360Cleaner.Library.ps1'
$script:SelectorLibraryLoadError = $null
$script:SelectorApp = $null
$script:SelectorFontScale = 1.0
$script:SelectorFontCache = @{}
$script:SelectorMutexName = 'Local\Windows360CleanerSelector'
$script:SelectorHelpIssueUrl = 'https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml'
$script:SelectorMaxSelected = 64
$script:SelectorProblemLineLimit = 5
$script:SelectorKeptLineLimit = 10

try {
    . $script:SelectorLibraryPath
}
catch {
    $script:SelectorLibraryLoadError = $_
}

# GUI-only strings. The shared library owns the table; these keys are added to it at load time.
# Every key lives in exactly one table (Add-W360Text refuses a key that already exists with other text).
$script:SelectorTexts = @{
    'Gui.Loading'                         = @('正在打开…', 'Opening...')
    'Gui.Progress.Starting'               = @('正在准备…', 'Getting ready...')
    'Gui.Progress.Cancelling'             = @('正在停止…', 'Stopping...')
    'Gui.Progress.PollProblem'            = @('暂时读不到进度，正在重试…', 'The progress cannot be read right now; trying again...')
    'Gui.Scan.DetailPlaceholder'          = @('点任意一行，这里会告诉你它是什么、删除后会怎样。', 'Click any row to see here what it is and what deleting it does.')
    'Gui.Scan.ItemPart'                   = @('{0}，属于“{1}”。', '{0}, part of "{1}".')
    'Gui.Scan.CoverageTitle'              = @('没检查完的地方', 'Places not fully checked')
    'Gui.Scan.CoverageIntro'              = @('下面这些地方没检查完，所以可能漏掉了一些 360 的东西。已经列出来的结果是准的。过一会儿可以再检查一次。', 'The places below were not fully checked, so some 360 items may have been missed. What is already listed is correct. You can check again a little later.')
    'Gui.Scan.NoIssuesRecorded'           = @('没有记录具体原因。', 'No specific reason was recorded.')
    'Gui.Plan.Intro'                      = @('还没有删除任何东西。', 'Nothing has been deleted yet.')
    'Gui.Plan.ResolutionLine'             = @('怎么办：{0}', 'What to do: {0}')
    'Gui.Plan.Repeated'                   = @('{0}（这样的有 {1} 项）', '{0} ({1} like this)')
    'Gui.Remove.NoProblems'               = @('没有记录到没删掉、跳过或没做完的操作。', 'No failed, skipped or unfinished actions were recorded.')
    'Gui.Remove.NoStats'                  = @('没有可用的统计。', 'No statistics are available.')
    'Gui.Remove.ProblemsTab'              = @('没删掉或没做完的（{0}）', 'Not deleted or unfinished ({0})')
    'Gui.Remove.StatLine'                 = @('{0}：{1}', '{0}: {1}')
    'Gui.Remove.LogTitle'                 = @('操作记录', 'Action log')
    'Gui.Remove.LogIntro'                 = @('下面是删除程序记录的每一步。“原始说明”是程序记录的英文原文，方便求助时核对。', 'Every step recorded by the deletion program. "Original detail" is the raw English text, useful when asking for help.')
    'Gui.Column.Target'                   = @('位置', 'Location')
    'Gui.Column.Action'                   = @('操作', 'Action')
    'Gui.Column.Result'                   = @('结果', 'Result')
    'Gui.Column.Reason'                   = @('原因', 'Reason')
    'Gui.Column.Time'                     = @('时间', 'Time')
    'Gui.Column.RawDetail'                = @('原始说明', 'Original detail')
    'Gui.Verify.SectionHeader'            = @('{0}（{1} 项）', '{0} ({1})')
    'Gui.Verify.DetailPlaceholder'        = @('点任意一行，这里会告诉你它现在是什么情况。', 'Click any row to see here what is going on with it now.')
    'Gui.Verify.ItemLine'                 = @('{0}：{1}', '{0}: {1}')
    'Gui.Verify.CoverageHint'             = @('这里没检查完。', 'This place was not fully checked.')
    'Gui.Detail.State'                    = @('结果', 'Result')
    'Gui.Detail.Explanation'              = @('说明', 'Explanation')
    'Gui.Detail.Kind'                     = @('类型', 'Type')
    'Gui.Detail.Location'                 = @('位置', 'Location')
    'Gui.Detail.RawDetail'                = @('原始说明（英文）', 'Original detail (English)')
    'Gui.Error.Unexpected.Headline'       = @('出了点问题', 'Something went wrong')
    'Gui.Error.Unexpected.Detail'         = @('界面出了点问题，当前操作已经停止。如果当时正在删除，不确定删了多少，请重启电脑后打开本工具再检查一次。', 'The window ran into a problem and the current operation stopped. If a deletion was running, it is not known how much was deleted; restart the PC, open this tool and check again.')
    'Gui.Error.UnexpectedDuringRemove'    = @('界面出了点问题，但删除还在进行。请不要关闭窗口，也不要关机，等它结束。', 'The window ran into a problem, but the deletion is still running. Do not close the window or shut down the PC; wait until it finishes.')
    'Gui.Error.ReportChanged.Headline'    = @('检查结果被改动了', 'The check result changed')
    'Gui.Error.StartFailed.Headline'      = @('没能开始检查', 'The check could not start')
    'Gui.Error.StartFailed.Detail'        = @('没能开始检查，没有删除任何东西。', 'The check could not start. Nothing was deleted.')
    'Gui.Error.TaskRecordFailed.Headline' = @('没有开始删除', 'The deletion did not start')
    'Gui.Error.TaskRecordFailed.Detail'   = @('没能保存这次删除的记录，所以没有开始删除，没有删除任何东西。', 'The record of this deletion could not be saved, so the deletion did not start and nothing was deleted.')
    'Gui.Error.RemoveStartFailed.Detail'  = @('删除没能开始，没有删除任何东西。', 'The deletion could not start. Nothing was deleted.')
    'Gui.Error.RemoveCrashed.Detail'      = @('读取删除结果时出了问题，不确定删了多少，不能当作已经删掉。请先保存好正在做的事，手动重启电脑，再打开本工具点“{0}”。', 'Something went wrong while reading the deletion result, so it is not known how much was deleted; do not treat anything as deleted. Save your work, restart the PC yourself, then open this tool and click "{0}".')
    'Gui.Error.TechnicalTitle'            = @('技术信息（求助时可以提供）', 'Technical details (useful when asking for help)')
    'Gui.Error.NoTechnical'               = @('没有更多技术信息。', 'No further technical details.')
    'Gui.Error.NextSteps'                 = @('可以重新检查电脑；一直这样的话，请点“{0}”。', 'You can check the PC again; if this keeps happening, click "{0}".')
    'Gui.Error.CancelledNext'             = @('可以重新检查电脑，或者直接关闭。', 'You can check the PC again or just close the tool.')
    'Gui.Fatal'                           = @('Windows 360 清理工具出了问题，已经停止。{0}{0}{1}', 'Windows 360 Cleaner ran into a problem and stopped.{0}{0}{1}')
    'Gui.Help.CopyDone'                   = @('已复制。', 'Copied.')
    'Gui.Help.CopyFailed'                 = @('复制失败：{0}', 'Copy failed: {0}')
    'Gui.Help.SaveFailed'                 = @('保存失败：{0}', 'Saving failed: {0}')
    'Gui.Help.BrowserFailed'              = @('打不开浏览器：{0}', 'The browser could not be opened: {0}')
    'Gui.OpenFolder.Failed'               = @('打不开文件夹：{0}', 'The folder could not be opened: {0}')
}

function Register-SelectorTexts {
    foreach ($key in @($script:SelectorTexts.Keys)) {
        $pair = $script:SelectorTexts[$key]
        Add-W360Text -Key $key -Chinese ([string]$pair[0]) -English ([string]$pair[1])
    }
}

if ($null -eq $script:SelectorLibraryLoadError) {
    try { Register-SelectorTexts }
    catch { $script:SelectorLibraryLoadError = $_ }
}

# Kept for scripts/Test-360Cleaner.ps1, which dot-sources this file with -InternalTestLibraryOnly.
function Test-FindingSelectable {
    param([object]$Finding)
    return [bool](Test-W360FindingSelectable -Finding $Finding)
}

function Initialize-SelectorWinForms {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
}

function Get-SelectorText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowNull()][AllowEmptyCollection()][object[]]$Arguments
    )

    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        return (Get-W360Text -Key $Key -Arguments $Arguments)
    }
    return (Get-W360Text -Key $Key)
}

function Set-SelectorFontScale {
    param([Parameter(Mandatory = $true)][ValidateRange(0.5, 3.0)][double]$Scale)
    $script:SelectorFontScale = $Scale
}

function Get-SelectorFont {
    param(
        [double]$Size = 9.5,
        [switch]$Bold
    )

    $family = if ((Get-W360UiLanguage) -eq 'zh') { 'Microsoft YaHei UI' } else { 'Segoe UI' }
    $scaled = [Math]::Round($Size * $script:SelectorFontScale, 2)
    $key = $family + '|' + $scaled.ToString([Globalization.CultureInfo]::InvariantCulture) + '|' + [string][bool]$Bold
    if (-not $script:SelectorFontCache.ContainsKey($key)) {
        $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
        $script:SelectorFontCache[$key] = New-Object Drawing.Font($family, [single]$scaled, $style, [Drawing.GraphicsUnit]::Point)
    }
    return $script:SelectorFontCache[$key]
}

function Get-SelectorColor {
    param([Parameter(Mandatory = $true)][string]$Name)

    $rgb = switch ($Name) {
        'Page' { @(247, 248, 250) }
        'Card' { @(255, 255, 255) }
        'HeaderBack' { @(28, 63, 110) }
        'HeaderText' { @(255, 255, 255) }
        'Text' { @(32, 32, 32) }
        'MutedText' { @(90, 90, 90) }
        'Primary' { @(0, 95, 184) }
        'Danger' { @(176, 38, 32) }
        'DisabledBack' { @(214, 214, 214) }
        'DisabledText' { @(120, 120, 120) }
        'Success' { @(16, 118, 16) }
        'Info' { @(0, 84, 153) }
        'Warning' { @(176, 72, 0) }
        'Error' { @(168, 32, 38) }
        'Neutral' { @(88, 88, 88) }
        'Banner' { @(255, 243, 199) }
        'BannerText' { @(92, 62, 0) }
        'GroupBack' { @(225, 233, 244) }
        'GroupSelectedBack' { @(196, 213, 236) }
        'ReviewBack' { @(246, 244, 238) }
        'ReviewText' { @(96, 96, 96) }
        'RowSelectedBack' { @(204, 228, 247) }
        default { @(32, 32, 32) }
    }
    return [Drawing.Color]::FromArgb([int]$rgb[0], [int]$rgb[1], [int]$rgb[2])
}

function Get-SelectorWindowSize {
    param([Parameter(Mandatory = $true)][object]$WorkingArea)

    $width = [Math]::Min(1180, [int][Math]::Floor([double]$WorkingArea.Width * 0.92))
    $height = [Math]::Min(800, [int][Math]::Floor([double]$WorkingArea.Height * 0.92))
    return New-Object Drawing.Size([Math]::Max(760, $width), [Math]::Max(540, $height))
}

function Get-SelectorDialogSize {
    param(
        [int]$Width,
        [int]$Height
    )

    $area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [Math]::Min($Width, [int][Math]::Floor($area.Width * 0.92))
    $h = [Math]::Min($Height, [int][Math]::Floor($area.Height * 0.92))
    return New-Object Drawing.Size([Math]::Max(560, $w), [Math]::Max(420, $h))
}

function Format-SelectorElapsed {
    param([TimeSpan]$Elapsed)

    $totalSeconds = [Math]::Max(0, [int][Math]::Floor($Elapsed.TotalSeconds))
    $hours = [int][Math]::Floor($totalSeconds / 3600)
    $minutes = [int][Math]::Floor(($totalSeconds % 3600) / 60)
    $seconds = $totalSeconds % 60
    if ($hours -gt 0) {
        return ('{0}:{1:00}:{2:00}' -f $hours, $minutes, $seconds)
    }
    return ('{0:00}:{1:00}' -f $minutes, $seconds)
}

function Get-SelectorSectionTitle {
    param([Parameter(Mandatory = $true)][string]$Text)
    return ([string][char]0x25A0 + ' ' + $Text)
}

function Get-SelectorTextTitle {
    param([Parameter(Mandatory = $true)][string]$Key)
    return (Get-SelectorSectionTitle -Text (Get-SelectorText -Key $Key))
}

function Join-SelectorLines {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Lines)
    return (@(@($Lines) | ForEach-Object { [string]$_ }) -join "`r`n")
}

function New-SelectorLabel {
    param(
        [AllowEmptyString()][string]$Text = '',
        [double]$FontSize = 9.5,
        [switch]$Bold,
        [string]$Color = 'Text',
        [string]$Name = ''
    )

    $label = New-Object Windows.Forms.Label
    $label.AutoSize = $true
    $label.Anchor = [Windows.Forms.AnchorStyles]'Left, Right'
    $label.UseMnemonic = $false
    $label.Text = $Text
    $label.Font = Get-SelectorFont -Size $FontSize -Bold:$Bold
    $label.ForeColor = Get-SelectorColor -Name $Color
    $label.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 3)
    if ($Name) { $label.Name = $Name }
    return $label
}

function New-SelectorLinkLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Name = '',
        [switch]$Bold
    )

    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = $Text
    $link.Name = $Name
    $link.AccessibleName = $Text
    $link.AutoSize = $true
    $link.UseMnemonic = $false
    $link.Font = Get-SelectorFont -Bold:$Bold
    $link.Margin = New-Object Windows.Forms.Padding(8, 3, 3, 3)
    return $link
}

function Update-SelectorButtonColors {
    param([Parameter(Mandatory = $true)][object]$Button)

    $style = [string]$Button.Tag
    if ($style -ne 'Primary' -and $style -ne 'Danger') { return }
    if ($Button.Enabled) {
        $Button.BackColor = Get-SelectorColor -Name $style
        $Button.ForeColor = Get-SelectorColor -Name 'HeaderText'
        $Button.FlatAppearance.BorderColor = Get-SelectorColor -Name $style
    }
    else {
        $Button.BackColor = Get-SelectorColor -Name 'DisabledBack'
        $Button.ForeColor = Get-SelectorColor -Name 'DisabledText'
        $Button.FlatAppearance.BorderColor = Get-SelectorColor -Name 'DisabledBack'
    }
}

function New-SelectorButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('Normal', 'Primary', 'Danger')][string]$Style = 'Normal',
        [string]$Name = ''
    )

    $button = New-Object Windows.Forms.Button
    $button.Text = $Text
    $button.Name = $Name
    $button.AccessibleName = $Text
    $button.UseMnemonic = $false
    $button.AutoSize = $true
    $button.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $button.MinimumSize = New-Object Drawing.Size(96, 32)
    $button.Padding = New-Object Windows.Forms.Padding(8, 1, 8, 1)
    $button.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 3)
    $button.Font = Get-SelectorFont -Bold:($Style -ne 'Normal')
    $button.Tag = $Style
    $button.UseVisualStyleBackColor = $true
    if ($Style -ne 'Normal') {
        $button.FlatStyle = [Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderSize = 1
        $button.UseVisualStyleBackColor = $false
        Update-SelectorButtonColors -Button $button
        $button.Add_EnabledChanged({
            param($sender, $eventInfo)
            try { Update-SelectorButtonColors -Button $sender } catch {}
        })
    }
    return $button
}

function New-SelectorReadOnlyTextBox {
    param(
        [AllowEmptyString()][string]$Text = '',
        [switch]$Editable
    )

    $box = New-Object Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = -not $Editable
    $box.WordWrap = $true
    $box.ScrollBars = [Windows.Forms.ScrollBars]::Vertical
    $box.Dock = [Windows.Forms.DockStyle]::Fill
    $box.BackColor = Get-SelectorColor -Name 'Card'
    $box.Font = Get-SelectorFont
    $box.MinimumSize = New-Object Drawing.Size(120, 60)
    $box.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 3)
    $box.Text = (($Text -replace "`r`n", "`n") -replace "`n", "`r`n")
    return $box
}

function Set-SelectorBoxText {
    param(
        [Parameter(Mandatory = $true)][object]$Box,
        [AllowEmptyString()][string]$Text
    )

    $Box.Text = (($Text -replace "`r`n", "`n") -replace "`n", "`r`n")
    $Box.SelectionStart = 0
    $Box.SelectionLength = 0
}

function New-SelectorTable {
    param(
        [int]$Columns = 1,
        [switch]$AutoSizeTable
    )

    $table = New-Object Windows.Forms.TableLayoutPanel
    $table.ColumnCount = $Columns
    $table.RowCount = 0
    $table.Margin = New-Object Windows.Forms.Padding(0)
    $table.Padding = New-Object Windows.Forms.Padding(0)
    if ($AutoSizeTable) {
        $table.AutoSize = $true
        $table.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    }
    return $table
}

function Add-SelectorTableRow {
    param(
        [Parameter(Mandatory = $true)][object]$Table,
        [AllowNull()][object]$Control,
        [ValidateSet('AutoSize', 'Percent', 'Absolute')][string]$SizeType = 'AutoSize',
        [single]$Height = 100,
        [int]$Column = 0,
        [int]$ColumnSpan = 1
    )

    $rowIndex = $Table.RowCount
    $Table.RowCount = $rowIndex + 1
    [void]$Table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::$SizeType, $Height)))
    if ($null -ne $Control) {
        $Table.Controls.Add($Control, $Column, $rowIndex)
        if ($ColumnSpan -gt 1) { $Table.SetColumnSpan($Control, $ColumnSpan) }
        $Control.TabIndex = $rowIndex
    }
    return $rowIndex
}

function New-SelectorPageObject {
    param([Parameter(Mandatory = $true)][string]$Kind)

    $root = New-SelectorTable -Columns 1
    $root.Dock = [Windows.Forms.DockStyle]::Fill
    $root.BackColor = Get-SelectorColor -Name 'Page'
    $root.Padding = New-Object Windows.Forms.Padding(12, 8, 12, 8)
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))

    $buttonBar = New-Object Windows.Forms.FlowLayoutPanel
    $buttonBar.FlowDirection = [Windows.Forms.FlowDirection]::LeftToRight
    $buttonBar.WrapContents = $true
    $buttonBar.AutoSize = $true
    $buttonBar.AutoSizeMode = [Windows.Forms.AutoSizeMode]::GrowAndShrink
    $buttonBar.Dock = [Windows.Forms.DockStyle]::Fill
    $buttonBar.Margin = New-Object Windows.Forms.Padding(0, 6, 0, 0)
    $buttonBar.Padding = New-Object Windows.Forms.Padding(0)
    $buttonBar.Name = 'ButtonBar'

    return [pscustomobject]@{
        Kind          = $Kind
        Root          = $root
        ButtonBar     = $buttonBar
        Buttons       = [ordered]@{}
        PrimaryButton = $null
        AcceptButton  = $null
        InitialFocus  = $null
        HeadlineLabel = $null
        DetailLabel   = $null
        Grid          = $null
        DetailBox     = $null
        Outcome       = $null
        Stage         = 'Error'
        ErrorText     = ''
        ReportPath    = ''
        Data          = @{}
    }
}

function Add-SelectorPageButton {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('Normal', 'Primary', 'Danger')][string]$Style = 'Normal',
        [AllowNull()][scriptblock]$OnClick
    )

    $button = New-SelectorButton -Text $Text -Style $Style -Name $Name
    $button.TabIndex = $Page.ButtonBar.Controls.Count
    $Page.ButtonBar.Controls.Add($button)
    $Page.Buttons[$Name] = $button
    if ($Style -ne 'Normal' -and $null -eq $Page.PrimaryButton) { $Page.PrimaryButton = $button }
    if ($null -ne $OnClick) { $button.Add_Click($OnClick) }
    return $button
}

function Add-SelectorPageHeadline {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [AllowEmptyString()][string]$Headline,
        [AllowEmptyString()][string]$Detail = '',
        [string]$Color = 'Text',
        [double]$FontSize = 12
    )

    $headlineLabel = New-SelectorLabel -Text $Headline -FontSize $FontSize -Bold -Color $Color -Name 'Headline'
    [void](Add-SelectorTableRow -Table $Page.Root -Control $headlineLabel)
    $Page.HeadlineLabel = $headlineLabel
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $detailLabel = New-SelectorLabel -Text $Detail -Name 'Detail'
        [void](Add-SelectorTableRow -Table $Page.Root -Control $detailLabel)
        $Page.DetailLabel = $detailLabel
    }
}

function Complete-SelectorPage {
    param([Parameter(Mandatory = $true)][object]$Page)

    [void](Add-SelectorTableRow -Table $Page.Root -Control $Page.ButtonBar)
    if ($null -eq $Page.InitialFocus) { $Page.InitialFocus = $Page.PrimaryButton }
    return $Page
}

# Headline colour name (for Get-SelectorColor) of any scan, remove or verify outcome: Success, Warning, Error,
# Neutral or Text. Failure, unknown, incomplete, restart-needed and cancelled results never get the success
# colour; the library owns the rule (Get-W360OutcomeTone).
function Get-SelectorOutcomeColor {
    param([AllowNull()][object]$Outcome)
    return [string](Get-W360OutcomeTone -Outcome $Outcome)
}

function Get-SelectorOutcomeString {
    param(
        [AllowNull()][object]$Outcome,
        [Parameter(Mandatory = $true)][string]$Name
    )
    return (Get-W360StringProperty -Object $Outcome -Name $Name)
}

function Get-SelectorNextStepsText {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Steps)

    $parts = @(@(Get-W360Items -Value $Steps) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($parts.Count -eq 0) { return '' }
    return (Get-SelectorText -Key 'Ui.NextSteps' -Arguments @(($parts -join (Get-SelectorText -Key 'Common.SentenceSeparator'))))
}

# Height of the short description area under a list: four lines normally, two with large fonts so the
# list keeps its height on small screens (the text box scrolls).
function Get-SelectorDetailAreaHeight {
    $lines = if ($script:SelectorFontScale -ge 1.25) { 2 } else { 4 }
    return [single]([int](Get-SelectorFont).Height * $lines + 14)
}

function New-SelectorMainForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = Get-SelectorText -Key 'App.WindowTitle' -Arguments @($script:W360ToolVersion)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = Get-SelectorFont
    $form.BackColor = Get-SelectorColor -Name 'Page'
    $form.MinimumSize = New-Object Drawing.Size(760, 540)
    $form.Size = Get-SelectorWindowSize -WorkingArea ([Windows.Forms.Screen]::PrimaryScreen.WorkingArea)
    $form.KeyPreview = $false

    $root = New-SelectorTable -Columns 1
    $root.Dock = [Windows.Forms.DockStyle]::Fill
    [void]$root.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))

    $header = New-SelectorTable -Columns 2 -AutoSizeTable
    $header.Dock = [Windows.Forms.DockStyle]::Fill
    $header.BackColor = Get-SelectorColor -Name 'HeaderBack'
    $header.Padding = New-Object Windows.Forms.Padding(12, 3, 12, 3)
    [void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $titleLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'App.Name') -FontSize 11 -Bold -Color 'HeaderText' -Name 'AppName'
    $versionLabel = New-SelectorLabel -Text ('v' + $script:W360ToolVersion) -FontSize 10 -Bold -Color 'HeaderText' -Name 'Version'
    $versionLabel.Anchor = [Windows.Forms.AnchorStyles]::Right
    $versionLabel.AccessibleName = $form.Text
    $header.RowCount = 1
    [void]$header.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
    $header.Controls.Add($titleLabel, 0, 0)
    $header.Controls.Add($versionLabel, 1, 0)

    $pageHost = New-Object Windows.Forms.Panel
    $pageHost.Dock = [Windows.Forms.DockStyle]::Fill
    $pageHost.Margin = New-Object Windows.Forms.Padding(0)
    $pageHost.Padding = New-Object Windows.Forms.Padding(0)
    $pageHost.BackColor = Get-SelectorColor -Name 'Page'
    $pageHost.Name = 'PageHost'

    [void](Add-SelectorTableRow -Table $root -Control $header)
    [void](Add-SelectorTableRow -Table $root -Control $pageHost -SizeType Percent -Height 100)
    $form.Controls.Add($root)

    $form.Add_FormClosing({
        param($sender, $closingInfo)
        Invoke-SelectorFormClosing -ClosingInfo $closingInfo
    })

    return [pscustomobject]@{
        Form          = $form
        Root          = $root
        Header        = $header
        TitleLabel    = $titleLabel
        VersionLabel  = $versionLabel
        PageHost      = $pageHost
        CurrentPage   = $null
        RetiredPages  = New-Object System.Collections.ArrayList
    }
}

function Set-SelectorPage {
    param(
        [Parameter(Mandatory = $true)][object]$Shell,
        [Parameter(Mandatory = $true)][object]$Page
    )

    if ($Shell.Form.IsDisposed) { return }
    # Pages retired earlier are disposed now; the page being replaced may still be inside its own click handler.
    foreach ($retired in @($Shell.RetiredPages)) {
        try { if (-not $retired.Root.IsDisposed) { $retired.Root.Dispose() } } catch {}
    }
    $Shell.RetiredPages.Clear()

    $hostPanel = $Shell.PageHost
    $hostPanel.SuspendLayout()
    try {
        if ($null -ne $Shell.CurrentPage) {
            $hostPanel.Controls.Remove($Shell.CurrentPage.Root)
            [void]$Shell.RetiredPages.Add($Shell.CurrentPage)
        }
        $hostPanel.Controls.Clear()
        $hostPanel.Controls.Add($Page.Root)
    }
    finally { $hostPanel.ResumeLayout($true) }
    $Shell.CurrentPage = $Page
    $Shell.Form.AcceptButton = $Page.AcceptButton
    if ($null -ne $Page.InitialFocus) {
        try { $Shell.Form.ActiveControl = $Page.InitialFocus } catch {}
    }
    # A grid selects its first row once it is attached and focused, which beginners can mistake for a choice.
    # Clearing the highlight (not the current cell, which would only select row 0 again on the next focus) fixes it.
    if ($null -ne $Page.Grid) {
        try { $Page.Grid.ClearSelection() } catch {}
    }
}

function New-SelectorLoadingPage {
    param([string]$Text = '')

    if ([string]::IsNullOrWhiteSpace($Text)) { $Text = Get-SelectorText -Key 'Gui.Loading' }
    $page = New-SelectorPageObject -Kind 'Loading'
    Add-SelectorPageHeadline -Page $page -Headline $Text
    [void](Add-SelectorTableRow -Table $page.Root -Control $null -SizeType Percent -Height 100)
    return (Complete-SelectorPage -Page $page)
}

function New-SelectorHomePage {
    param([Parameter(Mandatory = $true)][object]$TaskState)

    $page = New-SelectorPageObject -Kind 'Home'
    $page.Data['TaskState'] = $TaskState
    Add-SelectorPageHeadline -Page $page -Headline (Get-SelectorText -Key 'Ui.Home.Title') -FontSize 13

    $card = New-SelectorTable -Columns 1 -AutoSizeTable
    $card.Dock = [Windows.Forms.DockStyle]::Fill
    $card.BackColor = Get-SelectorColor -Name 'Card'
    $card.Padding = New-Object Windows.Forms.Padding(12, 10, 12, 10)
    $card.Margin = New-Object Windows.Forms.Padding(3, 8, 3, 8)
    $card.Name = 'TaskCard'
    [void]$card.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))

    $time = Get-W360PropertyValue -Object $TaskState -Name 'RemoveTimestamp'
    if ($null -eq $time) {
        $time = Get-W360PropertyValue -Object (Get-W360PropertyValue -Object $TaskState -Name 'TaskInfo') -Name 'CreatedAt'
    }
    $timeText = if ($time -is [DateTime]) {
        $time.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
    elseif ($null -ne $time) { [string]$time }
    else { Get-SelectorText -Key 'Common.Unknown' }
    $timeLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.TaskTime' -Arguments @($timeText)) -FontSize 10.5 -Bold -Name 'TaskTime'
    # These counts describe what was selected, not what was proven deleted.
    $countLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.Counts' -Arguments @(
            [int](Get-W360PropertyValue -Object $TaskState -Name 'SelectedCount' -Default 0),
            [int](Get-W360PropertyValue -Object $TaskState -Name 'PreservedCount' -Default 0))) -Name 'TaskCounts'
    $restarted = Get-W360PropertyValue -Object $TaskState -Name 'RestartedSinceRemove'
    if ($restarted -eq $true) {
        $restartLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.Restarted') -Color 'Success' -Name 'RestartState'
    }
    elseif ($restarted -eq $false) {
        $restartLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.NotRestarted') -Bold -Color 'Warning' -Name 'RestartState'
    }
    else {
        $restartLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.RestartUnknown') -Color 'MutedText' -Name 'RestartState'
    }
    [void](Add-SelectorTableRow -Table $card -Control $timeLabel)
    [void](Add-SelectorTableRow -Table $card -Control $countLabel)
    [void](Add-SelectorTableRow -Table $card -Control $restartLabel)
    $newerUnusable = [int](Get-W360PropertyValue -Object $TaskState -Name 'NewerUnusableCount' -Default 0)
    if ($newerUnusable -gt 0) {
        $newerLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.NewerUnusable' -Arguments @($newerUnusable)) -Color 'MutedText' -Name 'NewerUnusable'
        [void](Add-SelectorTableRow -Table $card -Control $newerLabel)
    }
    [void](Add-SelectorTableRow -Table $page.Root -Control $card)
    $page.Data['RestartLabel'] = $restartLabel

    $note = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Home.ReadOnlyNote') -Color 'MutedText' -Name 'ReadOnlyNote'
    [void](Add-SelectorTableRow -Table $page.Root -Control $note)
    [void](Add-SelectorTableRow -Table $page.Root -Control $null -SizeType Percent -Height 100)

    [void](Add-SelectorPageButton -Page $page -Name 'VerifyTask' -Text (Get-SelectorText -Key 'Ui.Button.VerifyTask') -Style Primary -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Start-SelectorTaskVerify -TaskState $script:SelectorApp.Shell.CurrentPage.Data['TaskState'] }
        })
    [void](Add-SelectorPageButton -Page $page -Name 'NewScan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Start-SelectorScan }
        })
    [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Close-SelectorApp }
        })
    $page.AcceptButton = $page.PrimaryButton
    return (Complete-SelectorPage -Page $page)
}

function New-SelectorProgressPage {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Verify', 'Remove')][string]$Kind,
        # A verify without a previous deletion record checks the whole PC; its title says so.
        [switch]$Global
    )

    $page = New-SelectorPageObject -Kind ('Progress' + $Kind)
    $page.Stage = $Kind
    $titleKey = 'Ui.Progress.Title.' + $Kind
    if ($Kind -eq 'Verify' -and $Global) { $titleKey = 'Ui.Progress.Title.VerifyGlobal' }
    # A deletion says "deleting" only once it has really started (Update-SelectorProgressPage moves it on).
    if ($Kind -eq 'Remove') { $titleKey = 'Ui.Progress.Title.RemovePreparing' }
    Add-SelectorPageHeadline -Page $page -Headline (Get-SelectorText -Key $titleKey) -FontSize 13

    $phaseLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Gui.Progress.Starting') -FontSize 11 -Bold -Color 'Info' -Name 'Phase'
    $phaseLabel.Margin = New-Object Windows.Forms.Padding(3, 12, 3, 3)
    $bar = New-Object Windows.Forms.ProgressBar
    $bar.Style = [Windows.Forms.ProgressBarStyle]::Marquee
    $bar.MarqueeAnimationSpeed = 30
    $bar.Height = 18
    $bar.Anchor = [Windows.Forms.AnchorStyles]'Left, Right'
    $bar.Margin = New-Object Windows.Forms.Padding(3, 8, 3, 6)
    $bar.Name = 'ProgressBar'
    $elapsedLabel = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Progress.Elapsed' -Arguments @('00:00')) -Color 'MutedText' -Name 'Elapsed'
    $noteKey = if ($Kind -eq 'Remove') { 'Ui.Progress.RemoveBeforeNote' } else { 'Ui.Progress.ReadOnlyNote' }
    $noteColor = if ($Kind -eq 'Remove') { 'Warning' } else { 'MutedText' }
    $note = New-SelectorLabel -Text (Get-SelectorText -Key $noteKey) -Bold:($Kind -eq 'Remove') -Color $noteColor -Name 'ProgressNote'
    $note.Margin = New-Object Windows.Forms.Padding(3, 12, 3, 3)

    [void](Add-SelectorTableRow -Table $page.Root -Control $phaseLabel)
    [void](Add-SelectorTableRow -Table $page.Root -Control $bar)
    [void](Add-SelectorTableRow -Table $page.Root -Control $elapsedLabel)
    [void](Add-SelectorTableRow -Table $page.Root -Control $note)
    [void](Add-SelectorTableRow -Table $page.Root -Control $null -SizeType Percent -Height 100)

    $page.Data['PhaseLabel'] = $phaseLabel
    $page.Data['ElapsedLabel'] = $elapsedLabel
    $page.Data['ProgressBar'] = $bar
    $page.Data['NoteLabel'] = $note
    $page.Data['RenderedEventCount'] = 0
    $page.Data['CurrentPhase'] = ''
    # Remove only: Preparing -> WaitingForPermission -> Deleting; it never moves back.
    $page.Data['RemoveStage'] = 'Preparing'
    $page.Data['CancelButton'] = $null
    if ($Kind -ne 'Remove') {
        # A check can always be stopped; a running deletion never offers a stop button.
        $cancel = Add-SelectorPageButton -Page $page -Name 'Cancel' -Text (Get-SelectorText -Key 'Ui.Button.StopCheck') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Stop-SelectorRunningJob }
        }
        $page.Data['CancelButton'] = $cancel
        $page.InitialFocus = $cancel
    }
    return (Complete-SelectorPage -Page $page)
}

function Update-SelectorProgressPage {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][object]$State
    )

    $events = @(Get-W360ArrayProperty -Object $State -Name 'Events')
    $rendered = [int]$Page.Data['RenderedEventCount']
    $isRemove = [string]$Page.Kind -ceq 'ProgressRemove'
    $removeStage = [string]$Page.Data['RemoveStage']
    for ($index = $rendered; $index -lt $events.Count; $index++) {
        $phase = Get-W360StringProperty -Object $events[$index] -Name 'Phase'
        if ($isRemove -and -not [string]::IsNullOrWhiteSpace($phase)) {
            if ($phase -ceq 'WaitingForElevation') {
                if ($removeStage -ceq 'Preparing') { $removeStage = 'WaitingForPermission' }
            }
            elseif ($script:W360RemoveStartedPhases -ccontains $phase) { $removeStage = 'Deleting' }
        }
        if ([string]::IsNullOrWhiteSpace($phase) -or $phase -ceq [string]$Page.Data['CurrentPhase']) { continue }
        $Page.Data['CurrentPhase'] = $phase
        $Page.Data['PhaseLabel'].Text = Get-W360PhaseText -Phase $phase
    }
    $Page.Data['RenderedEventCount'] = $events.Count
    if ($isRemove -and $removeStage -cne [string]$Page.Data['RemoveStage']) {
        $Page.Data['RemoveStage'] = $removeStage
        $titleKey = if ($removeStage -ceq 'Deleting') { 'Ui.Progress.Title.Remove' } else { 'Ui.Progress.Title.RemoveWaiting' }
        $Page.HeadlineLabel.Text = Get-SelectorText -Key $titleKey
        if ($removeStage -ceq 'Deleting') { $Page.Data['NoteLabel'].Text = Get-SelectorText -Key 'Ui.Progress.RemoveNote' }
    }

    $elapsed = [TimeSpan]::Zero
    $stopwatch = Get-W360PropertyValue -Object $State -Name 'Stopwatch'
    if ($null -ne $stopwatch) { $elapsed = $stopwatch.Elapsed }
    else {
        $value = Get-W360PropertyValue -Object $State -Name 'Elapsed'
        if ($value -is [TimeSpan]) { $elapsed = $value }
    }
    $Page.Data['ElapsedLabel'].Text = Get-SelectorText -Key 'Ui.Progress.Elapsed' -Arguments @(Format-SelectorElapsed -Elapsed $elapsed)
}

function New-SelectorErrorPage {
    param(
        [Parameter(Mandatory = $true)][string]$Headline,
        [AllowEmptyString()][string]$Detail = '',
        [AllowNull()][AllowEmptyString()][string]$ErrorText = '',
        [ValidateSet('Scan', 'Remove', 'Verify', 'Error')][string]$Stage = 'Error',
        [AllowNull()][object]$Outcome = $null,
        [AllowNull()][AllowEmptyString()][string]$ReportPath = '',
        [ValidateSet('Error', 'Neutral', 'Warning')][string]$Tone = 'Error',
        [AllowNull()][AllowEmptyString()][string]$NextSteps = $null
    )

    $page = New-SelectorPageObject -Kind 'Error'
    $page.Stage = $Stage
    $page.Outcome = $Outcome
    $page.ErrorText = [string]$ErrorText
    $page.ReportPath = [string]$ReportPath
    Add-SelectorPageHeadline -Page $page -Headline $Headline -Detail $Detail -Color $Tone -FontSize 13

    if (-not $PSBoundParameters.ContainsKey('NextSteps')) {
        $NextSteps = Get-SelectorText -Key 'Gui.Error.NextSteps' -Arguments @((Get-SelectorText -Key 'Ui.Button.HelpSummary'))
    }
    if (-not [string]::IsNullOrWhiteSpace($NextSteps)) {
        $next = New-SelectorLabel -Text (Get-SelectorNextStepsText -Steps @($NextSteps)) -Bold -Color 'Info' -Name 'NextSteps'
        $next.Margin = New-Object Windows.Forms.Padding(3, 10, 3, 3)
        [void](Add-SelectorTableRow -Table $page.Root -Control $next)
    }
    # The technical reason is one click away, never on the page itself.
    $page.Data['TechnicalLink'] = $null
    if (-not [string]::IsNullOrWhiteSpace($ErrorText)) {
        $link = New-SelectorLinkLabel -Text (Get-SelectorText -Key 'Ui.Button.MoreInfo') -Name 'TechnicalLink'
        $link.Anchor = [Windows.Forms.AnchorStyles]::Left
        $link.Margin = New-Object Windows.Forms.Padding(3, 10, 3, 3)
        $link.Tag = $page
        $link.Add_LinkClicked({
                param($sender, $linkInfo)
                Invoke-SelectorUiAction -SelectorAction { Show-SelectorTechnicalText -Page $sender.Tag }
            })
        [void](Add-SelectorTableRow -Table $page.Root -Control $link)
        $page.Data['TechnicalLink'] = $link
    }
    [void](Add-SelectorTableRow -Table $page.Root -Control $null -SizeType Percent -Height 100)

    [void](Add-SelectorPageButton -Page $page -Name 'Rescan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -Style Primary -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Start-SelectorScan }
        })
    [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Show-SelectorHelpSummaryForPage -Page $script:SelectorApp.Shell.CurrentPage }
        })
    [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Close-SelectorApp }
        })
    return (Complete-SelectorPage -Page $page)
}

function New-SelectorNoMatchPage {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    $state = Get-SelectorOutcomeString -Outcome $Outcome -Name 'State'
    $page = New-SelectorPageObject -Kind 'NoMatch'
    $page.Stage = 'Scan'
    $page.Outcome = $Outcome
    $page.ReportPath = Get-SelectorOutcomeString -Outcome $Outcome -Name 'ReportPath'
    Add-SelectorPageHeadline -Page $page -Headline (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Headline') `
        -Detail (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Detail') -Color (Get-SelectorOutcomeColor -Outcome $Outcome) -FontSize 13

    # "Nothing found" and "not fully checked" stay different: the incomplete page names the unchecked places.
    $incomplete = $state -eq 'NoMatchesIncomplete'
    $page.Data['CoverageLink'] = $null
    if ($incomplete) {
        $link = New-SelectorLinkLabel -Text (Get-SelectorText -Key 'Ui.Button.CoverageDetails') -Name 'CoverageDetails' -Bold
        $link.Anchor = [Windows.Forms.AnchorStyles]::Left
        $link.Margin = New-Object Windows.Forms.Padding(3, 6, 3, 3)
        $link.Tag = $page
        $link.Add_LinkClicked({
                param($sender, $linkInfo)
                Invoke-SelectorUiAction -SelectorAction { Show-SelectorCoverageDialog -Issues @(Get-W360ArrayProperty -Object $sender.Tag.Outcome -Name 'CoverageIssues') }
            })
        [void](Add-SelectorTableRow -Table $page.Root -Control $link)
        $page.Data['CoverageLink'] = $link
    }
    [void](Add-SelectorTableRow -Table $page.Root -Control $null -SizeType Percent -Height 100)

    $rescanHandler = { Invoke-SelectorUiAction -SelectorAction { Start-SelectorScan } }
    $closeHandler = { Invoke-SelectorUiAction -SelectorAction { Close-SelectorApp } }
    if ($incomplete) {
        [void](Add-SelectorPageButton -Page $page -Name 'Rescan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -Style Primary -OnClick $rescanHandler)
        [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick $closeHandler)
    }
    else {
        [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -Style Primary -OnClick $closeHandler)
        [void](Add-SelectorPageButton -Page $page -Name 'Rescan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -OnClick $rescanHandler)
    }
    [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Show-SelectorHelpSummaryForPage -Page $script:SelectorApp.Shell.CurrentPage }
        })
    return (Complete-SelectorPage -Page $page)
}

function Get-SelectorCoverageIssueText {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Issues,
        # Plain: only "place: not fully checked"; the raw target and English detail stay in Details and Get help.
        [switch]$Plain
    )

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($issue in @(Get-W360Items -Value $Issues)) {
        $fields = if ($Plain) { @((Get-W360StringProperty -Object $issue -Name 'Text')) }
        else {
            @((Get-W360StringProperty -Object $issue -Name 'Text'), (Get-W360StringProperty -Object $issue -Name 'Target'),
                (Get-W360StringProperty -Object $issue -Name 'Detail'))
        }
        $parts = @($fields | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Count -gt 0) {
            $line = [string][char]0x00B7 + ' ' + ($parts -join ' - ')
            if (-not $lines.Contains($line)) { $lines.Add($line) }
        }
    }
    if ($lines.Count -eq 0) { return (Get-SelectorText -Key 'Gui.Scan.NoIssuesRecorded') }
    return ($lines.ToArray() -join "`r`n")
}

function New-SelectorDialogShell {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [int]$Width = 720,
        [int]$Height = 540,
        [int]$MinimumWidth = 560,
        [int]$MinimumHeight = 420
    )

    $form = New-Object Windows.Forms.Form
    $form.Text = $Title
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $form.Font = Get-SelectorFont
    $form.BackColor = Get-SelectorColor -Name 'Page'
    $form.MinimizeBox = $false
    $form.MaximizeBox = $true
    $form.ShowInTaskbar = $false
    $form.ShowIcon = $false
    $form.MinimumSize = New-Object Drawing.Size($MinimumWidth, $MinimumHeight)
    $form.Size = Get-SelectorDialogSize -Width $Width -Height $Height

    $page = New-SelectorPageObject -Kind 'Dialog'
    $form.Controls.Add($page.Root)
    $page.Data['Form'] = $form
    $form.Tag = $page
    $form.Add_Shown({
            param($sender, $shownInfo)
            try {
                $dialogPage = $sender.Tag
                if ($null -ne $dialogPage -and $null -ne $dialogPage.InitialFocus) { $sender.ActiveControl = $dialogPage.InitialFocus }
            }
            catch {}
        })
    return $page
}

function Show-SelectorDialog {
    param([Parameter(Mandatory = $true)][object]$Dialog)

    $form = $Dialog.Data['Form']
    try {
        $owner = $null
        if ($null -ne $script:SelectorApp -and -not $script:SelectorApp.Form.IsDisposed) { $owner = $script:SelectorApp.Form }
        if ($null -ne $owner) { return $form.ShowDialog($owner) }
        return $form.ShowDialog()
    }
    finally { $form.Dispose() }
}

function New-SelectorTextDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [AllowEmptyString()][string]$Intro = '',
        [AllowEmptyString()][string]$Body = ''
    )

    $dialog = New-SelectorDialogShell -Title $Title -Width 680 -Height 480
    $dialog.Kind = 'TextDialog'
    Add-SelectorPageHeadline -Page $dialog -Headline $Title -Detail $Intro
    $box = New-SelectorReadOnlyTextBox -Text $Body
    $box.Name = 'Body'
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $box -SizeType Percent -Height 100)
    $dialog.DetailBox = $box
    $close = Add-SelectorPageButton -Page $dialog -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -Style Primary
    $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Data['Form'].AcceptButton = $close
    $dialog.Data['Form'].CancelButton = $close
    return (Complete-SelectorPage -Page $dialog)
}

function New-SelectorCoverageDialog {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Issues)

    return (New-SelectorTextDialog -Title (Get-SelectorText -Key 'Gui.Scan.CoverageTitle') `
            -Intro (Get-SelectorText -Key 'Gui.Scan.CoverageIntro') -Body (Get-SelectorCoverageIssueText -Issues $Issues -Plain))
}

function New-SelectorGrid {
    param([string]$Name = 'Grid')

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Name = $Name
    $grid.Dock = [Windows.Forms.DockStyle]::Fill
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.AllowUserToOrderColumns = $false
    $grid.ReadOnly = $true
    $grid.EditMode = [Windows.Forms.DataGridViewEditMode]::EditProgrammatically
    $grid.MultiSelect = $false
    $grid.SelectionMode = [Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $grid.RowHeadersVisible = $false
    $grid.AutoSizeColumnsMode = [Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $grid.AutoSizeRowsMode = [Windows.Forms.DataGridViewAutoSizeRowsMode]::None
    $grid.ColumnHeadersHeightSizeMode = [Windows.Forms.DataGridViewColumnHeadersHeightSizeMode]::AutoSize
    $grid.BackgroundColor = Get-SelectorColor -Name 'Card'
    $grid.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
    $grid.CellBorderStyle = [Windows.Forms.DataGridViewCellBorderStyle]::SingleHorizontal
    $grid.GridColor = [Drawing.Color]::FromArgb(226, 229, 234)
    $grid.StandardTab = $true
    $grid.ShowCellToolTips = $true
    $grid.Font = Get-SelectorFont
    $grid.ColumnHeadersDefaultCellStyle.Font = Get-SelectorFont -Bold
    $grid.ColumnHeadersDefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::False
    $grid.DefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::False
    $grid.DefaultCellStyle.SelectionBackColor = Get-SelectorColor -Name 'RowSelectedBack'
    $grid.DefaultCellStyle.SelectionForeColor = Get-SelectorColor -Name 'Text'
    $grid.RowTemplate.Height = [Math]::Max(26, [int]$grid.Font.Height + 12)
    # Rows that size themselves to wrapped text never get shorter than a comfortable single line.
    $grid.RowTemplate.MinimumHeight = $grid.RowTemplate.Height
    $grid.MinimumSize = New-Object Drawing.Size(160, 120)
    $grid.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 3)
    # A freshly shown grid highlights its first row, which beginners can mistake for a choice.
    $grid.Add_HandleCreated({
            param($sender, $handleInfo)
            try { $sender.ClearSelection() } catch {}
        })
    $grid.Add_VisibleChanged({
            param($sender, $visibleInfo)
            try { if ($sender.Visible -and -not $sender.ContainsFocus) { $sender.ClearSelection() } } catch {}
        })
    # Never let a formatting problem pop up the default DataGridView error dialog.
    $grid.Add_DataError({
            param($sender, $dataErrorInfo)
            try { $dataErrorInfo.ThrowException = $false } catch {}
        })
    return $grid
}

# A list must always show its header and at least Rows whole rows; the description area gives up its height first.
function Set-SelectorGridMinimumRows {
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [int]$Rows = 3
    )

    $header = [int](Get-SelectorFont -Bold).Height + 14
    $height = $header + $Rows * [int]$Grid.RowTemplate.Height + 4
    $Grid.MinimumSize = New-Object Drawing.Size(160, [Math]::Max(120, $height))
}

function Add-SelectorTextColumn {
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$HeaderText,
        [single]$FillWeight = 20,
        [int]$MinimumWidth = 60,
        [switch]$Wrap
    )

    $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $Name
    $column.HeaderText = $HeaderText
    $column.FillWeight = $FillWeight
    $column.MinimumWidth = $MinimumWidth
    $column.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $column.ReadOnly = $true
    if ($Wrap) {
        # Long plain answers ("can be deleted (1), 1 not deleted") wrap instead of being cut off with large fonts;
        # the rows grow to fit (the grid sizes its displayed rows).
        $column.DefaultCellStyle.WrapMode = [Windows.Forms.DataGridViewTriState]::True
        $Grid.AutoSizeRowsMode = [Windows.Forms.DataGridViewAutoSizeRowsMode]::DisplayedCells
    }
    [void]$Grid.Columns.Add($column)
    return $column
}

# The short description area under a list: a read-only text box and a small "More info" link.
function Add-SelectorDetailArea {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][string]$BoxName,
        [AllowEmptyString()][string]$Placeholder = ''
    )

    $area = New-SelectorTable -Columns 2
    $area.Dock = [Windows.Forms.DockStyle]::Fill
    $area.Name = 'DetailArea'
    [void]$area.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$area.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $area.RowCount = 1
    [void]$area.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))

    $box = New-SelectorReadOnlyTextBox -Text $Placeholder
    $box.Name = $BoxName
    $box.MinimumSize = New-Object Drawing.Size(120, 40)
    $box.BackColor = Get-SelectorColor -Name 'Page'
    $link = New-SelectorLinkLabel -Text (Get-SelectorText -Key 'Ui.Button.MoreInfo') -Name 'MoreInfo'
    $link.Anchor = [Windows.Forms.AnchorStyles]'Top, Right'
    $link.Enabled = $false
    $link.Tag = $Page
    $link.Add_LinkClicked({
            param($sender, $linkInfo)
            Invoke-SelectorUiAction -SelectorAction { Show-SelectorItemInfo -Page $sender.Tag }
        })
    $area.Controls.Add($box, 0, 0)
    $area.Controls.Add($link, 1, 0)
    $box.TabIndex = 0
    $link.TabIndex = 1
    $height = Get-SelectorDetailAreaHeight
    $areaRow = Add-SelectorTableRow -Table $Page.Root -Control $area -SizeType Absolute -Height $height
    $Page.DetailBox = $box
    $Page.Data['MoreInfoLink'] = $link
    $Page.Data['InfoRowIndex'] = -1
    $Page.Data['DetailArea'] = $area
    $Page.Data['DetailAreaHidden'] = $false
    $Page.Data['DetailAreaRow'] = $areaRow
    $Page.Data['DetailAreaHeight'] = $height
    # On a small window with large text the description area gives up height before the list does.
    $Page.Root.Tag = $Page
    $Page.Root.Add_Layout({
            param($sender, $layoutInfo)
            try { Update-SelectorDetailAreaFit -Page $sender.Tag } catch {}
        })
    return $area
}

# Height of the description area that still leaves the list its minimum height: the normal height (less the
# selection note while it shows), else whatever fits down to one line, else the area is hidden.
function Update-SelectorDetailAreaFit {
    param([AllowNull()][object]$Page)

    if ($null -eq $Page -or -not $Page.Data.ContainsKey('DetailAreaRow') -or $null -eq $Page.Grid) { return }
    $root = $Page.Root
    $area = $Page.Data['DetailArea']
    $box = $Page.DetailBox
    $note = $Page.Data['SelectionNote']
    $noteShown = $null -ne $note -and -not [string]::IsNullOrWhiteSpace([string]$note.Text)
    $oneLine = [single][Math]::Max(([int](Get-SelectorFont).Height + 16), ($box.MinimumSize.Height + $box.Margin.Vertical + 2))
    $height = [single]$Page.Data['DetailAreaHeight']
    if ($noteShown) { $height = [single][Math]::Max($oneLine, $height - ($note.Height + $note.Margin.Vertical)) }

    $width = $root.ClientSize.Width - $root.Padding.Horizontal
    if ($width -gt 0 -and $root.ClientSize.Height -gt 0) {
        $used = $root.Padding.Vertical
        foreach ($control in $root.Controls) {
            if ([object]::ReferenceEquals($control, $area)) { continue }
            if ([object]::ReferenceEquals($control, $note) -and -not $noteShown) { continue }
            if ([object]::ReferenceEquals($control, $Page.Grid)) {
                $used += $Page.Grid.MinimumSize.Height + $Page.Grid.Margin.Vertical
                continue
            }
            $controlHeight = $control.Height
            if ($control.AutoSize) {
                $controlHeight = $control.GetPreferredSize((New-Object Drawing.Size([Math]::Max(1, $width - $control.Margin.Horizontal), 0))).Height
            }
            $used += $controlHeight + $control.Margin.Vertical
        }
        $available = [single]($root.ClientSize.Height - $used)
        if ($available -lt $height) { $height = if ($available -ge $oneLine) { $available } else { [single]0 } }
    }

    # Visible reads false until the window is shown, so the page keeps its own flag (no layout loop).
    $hidden = -not ($height -gt 0)
    if ([bool]$Page.Data['DetailAreaHidden'] -ne $hidden) {
        $Page.Data['DetailAreaHidden'] = $hidden
        $area.Visible = -not $hidden
    }
    $style = $root.RowStyles[[int]$Page.Data['DetailAreaRow']]
    if ([Math]::Abs($style.Height - $height) -ge 1) { $style.Height = $height }
}

# Remembers which row "More info" describes; only item rows (not product or section rows) have more info.
function Set-SelectorInfoRow {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex = -1
    )

    $Page.Data['InfoRowIndex'] = $RowIndex
    $link = $Page.Data['MoreInfoLink']
    if ($null -ne $link) { $link.Enabled = ($RowIndex -ge 0) }
}

function Get-SelectorGroupHeaderText {
    param(
        [Parameter(Mandatory = $true)][object]$Group,
        [bool]$Collapsed = $true
    )

    $arrow = if ($Collapsed) { [string][char]0x25B6 } else { [string][char]0x25BC }
    return (Get-SelectorText -Key 'Ui.Group.Header' -Arguments @($arrow, [string]$Group.DisplayName))
}

# Short description of one item: what it is, then what deleting does or why it is kept. Effective is the page's
# effectively deletable set: an item outside it is described as kept.
function Get-SelectorFindingDetailText {
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [AllowNull()][object]$Effective
    )

    $status = Get-W360FindingStatus -Finding $Finding -Effective $Effective
    $product = Get-W360ProductInfo -ProductKey (Get-W360StringProperty -Object $Finding -Name 'ProductKey')
    $name = Get-W360FindingDisplayName -Finding $Finding
    $kindText = Get-W360FindingKindText -Finding $Finding
    # "Duohui installation folder: folder" says the same thing twice, so the kind is left out when the name has it.
    $what = if ($name.IndexOf($kindText, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
        Get-SelectorText -Key 'Gui.Scan.ItemPart' -Arguments @($name, $product.DisplayName)
    }
    else {
        Get-SelectorText -Key 'Ui.Detail.ItemWhat' -Arguments @($name, $kindText, $product.DisplayName)
    }
    if ([bool]$status.Deletable) {
        # "Can be deleted" is never advice: the explanation says the user decides and that nothing goes to the Recycle Bin.
        return (Join-SelectorLines -Lines @($what,
                (Get-SelectorText -Key 'Ui.Detail.AfterDelete' -Arguments @((Get-W360ImpactText -Finding $Finding))),
                $status.Explanation))
    }
    return (Join-SelectorLines -Lines @($what, (Get-SelectorText -Key 'Ui.Detail.WhyKept' -Arguments @($status.Explanation))))
}

# Full technical description of one item for the More info window.
function Get-SelectorFindingInfoText {
    param(
        [Parameter(Mandatory = $true)][object]$Finding,
        [AllowNull()][object]$Effective
    )

    $status = Get-W360FindingStatus -Finding $Finding -Effective $Effective
    $product = Get-W360ProductInfo -ProductKey (Get-W360StringProperty -Object $Finding -Name 'ProductKey')
    $lines = @(
        (Get-W360FindingDisplayName -Finding $Finding),
        '',
        (Get-SelectorTextTitle -Key 'Ui.Detail.Status'),
        $status.Text,
        $status.Explanation,
        '',
        (Get-SelectorTextTitle -Key 'Ui.Detail.Reason'),
        (Get-W360ReasonText -Finding $Finding),
        '',
        (Get-SelectorTextTitle -Key 'Ui.Detail.Impact'),
        (Get-W360ImpactText -Finding $Finding -Effective $Effective),
        '',
        (Get-SelectorTextTitle -Key 'Ui.Detail.Product'),
        $product.DisplayName,
        $product.Description,
        '',
        (Get-SelectorTextTitle -Key 'Ui.Detail.Technical'),
        (Get-W360FindingTechnicalText -Finding $Finding)
    )
    return (Join-SelectorLines -Lines $lines)
}

function Get-SelectorGroupDetailText {
    param([Parameter(Mandatory = $true)][object]$Group)

    return (Join-SelectorLines -Lines @(
            (Get-SelectorText -Key 'Ui.Detail.GroupWhat' -Arguments @([string]$Group.DisplayName, [string]$Group.Description)),
            (Get-SelectorText -Key 'Ui.Detail.GroupCounts' -Arguments @([int]$Group.SelectableCount, [int]$Group.ReviewCount))
        ))
}

function New-SelectorScanResultPage {
    param(
        [Parameter(Mandatory = $true)][object]$Outcome,
        [AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds = @()
    )

    $page = New-SelectorPageObject -Kind 'ScanResult'
    $page.Stage = 'Scan'
    $page.Outcome = $Outcome
    $page.ReportPath = Get-SelectorOutcomeString -Outcome $Outcome -Name 'ReportPath'
    $findings = @(Get-W360ArrayProperty -Object $Outcome -Name 'Findings')
    # Only effectively deletable items can be ticked: a deletable item that can never pass the selection check in this
    # check result (for example a folder that holds something that is kept) is shown as "won't delete". The scan
    # outcome works the set out once; it only ever narrows what Test-W360FindingSelectable allows.
    $effective = Get-W360OutcomeEffectiveDeletable -Outcome $Outcome
    $page.Data['Effective'] = $effective

    $selectableById = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($finding in $findings) {
        if (-not (Test-W360FindingDeletable -Finding $finding -Effective $effective)) { continue }
        $id = ([string]$finding.SelectionId).Trim().ToUpperInvariant()
        if (-not $selectableById.ContainsKey($id)) { $selectableById[$id] = $finding }
    }
    # The selection lives here, keyed by SelectionId; grid cells only mirror it. It starts empty unless the
    # caller hands back a selection the user already made.
    $selection = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $SelectedIds)) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ($selectableById.ContainsKey($id) -and -not $selection.ContainsKey($id)) { $selection[$id] = $selectableById[$id] }
    }
    $page.Data['SelectableById'] = $selectableById
    $page.Data['Selection'] = $selection
    # Without anything that can be deleted the page only explains; it offers no ticking or deleting controls.
    $hasDeletable = $selectableById.Count -gt 0
    $page.Data['HasDeletable'] = $hasDeletable

    Add-SelectorPageHeadline -Page $page -Headline (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Headline') `
        -Detail (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Detail') -Color (Get-SelectorOutcomeColor -Outcome $Outcome)

    # One tooltip component shows the full text of the one-line labels (banner, counter, note).
    $noteTip = New-Object Windows.Forms.ToolTip
    $page.Root.Add_Disposed({ try { $noteTip.Dispose() } catch {} }.GetNewClosure())
    $page.Data['SelectionNoteTip'] = $noteTip
    $page.Data['Banner'] = $null
    $page.Data['CoverageLink'] = $null
    if ((Get-W360PropertyValue -Object $Outcome -Name 'CoverageComplete') -eq $false) {
        $banner = New-SelectorTable -Columns 2 -AutoSizeTable
        $banner.Dock = [Windows.Forms.DockStyle]::Fill
        $banner.BackColor = Get-SelectorColor -Name 'Banner'
        $banner.Padding = New-Object Windows.Forms.Padding(8, 1, 4, 1)
        $banner.Margin = New-Object Windows.Forms.Padding(3, 2, 3, 2)
        $banner.Name = 'CoverageBanner'
        [void]$banner.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
        [void]$banner.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
        $bannerLabel = New-SelectorLabel -Text ([string][char]0x26A0 + ' ' + (Get-SelectorText -Key 'Ui.Scan.CoverageBanner')) -Bold -Color 'BannerText' -Name 'CoverageBannerText'
        # One line even with long text or large fonts; the full sentence is in the tooltip and the accessible name.
        $bannerLabel.AutoSize = $false
        $bannerLabel.AutoEllipsis = $true
        $bannerLabel.Height = [int](Get-SelectorFont -Bold).Height + 4
        $bannerLabel.AccessibleName = $bannerLabel.Text
        $noteTip.SetToolTip($bannerLabel, $bannerLabel.Text)
        $detailsLink = New-SelectorLinkLabel -Text (Get-SelectorText -Key 'Ui.Button.CoverageDetails') -Name 'CoverageDetails' -Bold
        $detailsLink.Anchor = [Windows.Forms.AnchorStyles]::Right
        $detailsLink.Tag = $page
        $detailsLink.Add_LinkClicked({
                param($sender, $linkInfo)
                Invoke-SelectorUiAction -SelectorAction {
                    Show-SelectorCoverageDialog -Issues @(Get-W360ArrayProperty -Object $sender.Tag.Outcome -Name 'CoverageIssues')
                }
            })
        $banner.RowCount = 1
        [void]$banner.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::AutoSize)))
        $banner.Controls.Add($bannerLabel, 0, 0)
        $banner.Controls.Add($detailsLink, 1, 0)
        [void](Add-SelectorTableRow -Table $page.Root -Control $banner)
        $page.Data['Banner'] = $banner
        $page.Data['CoverageLink'] = $detailsLink
    }

    $grid = New-SelectorGrid -Name 'FindingGrid'
    $checkColumn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $checkColumn.Name = 'Select'
    $checkColumn.HeaderText = Get-SelectorText -Key 'Ui.Column.Select'
    $checkColumn.AutoSizeMode = [Windows.Forms.DataGridViewAutoSizeColumnMode]::None
    $checkColumn.Resizable = [Windows.Forms.DataGridViewTriState]::False
    $checkColumn.SortMode = [Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    $checkColumn.ReadOnly = $true
    # Two-state cells only: a mixed product row is painted by Invoke-SelectorGridCellPainting instead.
    $checkColumn.ThreeState = $false
    $checkColumn.Width = [Math]::Max(56, [Windows.Forms.TextRenderer]::MeasureText($checkColumn.HeaderText, (Get-SelectorFont -Bold)).Width + 22)
    [void]$grid.Columns.Add($checkColumn)
    [void](Add-SelectorTextColumn -Grid $grid -Name 'Item' -HeaderText (Get-SelectorText -Key 'Ui.Column.Item') -FillWeight 55 -MinimumWidth 120 -Wrap)
    [void](Add-SelectorTextColumn -Grid $grid -Name 'Decision' -HeaderText (Get-SelectorText -Key 'Ui.Column.Decision') -FillWeight 45 -MinimumWidth 100 -Wrap)

    Set-SelectorGridMinimumRows -Grid $grid -Rows 3
    $groupFont = Get-SelectorFont -Bold
    $indent = [int][Math]::Round(22 * $script:SelectorFontScale)
    $groupInfos = New-Object System.Collections.ArrayList
    foreach ($group in @(Get-W360FindingGroups -Findings $findings -Effective $effective)) {
        $headerIndex = $grid.Rows.Add()
        $headerRow = $grid.Rows[$headerIndex]
        $selectableGroup = @($group.SelectableIds).Count -gt 0
        $info = [pscustomobject]@{
            Type        = 'Group'
            Group       = $group
            HeaderIndex = $headerIndex
            Collapsed   = $true
            Selectable  = $selectableGroup
            RowIndexes  = New-Object System.Collections.Generic.List[int]
            CheckState  = 'Disabled'
        }
        [void]$groupInfos.Add($info)
        $headerRow.Tag = $info
        $headerRow.DefaultCellStyle.BackColor = Get-SelectorColor -Name 'GroupBack'
        $headerRow.DefaultCellStyle.SelectionBackColor = Get-SelectorColor -Name 'GroupSelectedBack'
        $headerRow.DefaultCellStyle.ForeColor = Get-SelectorColor -Name 'Text'
        $headerRow.DefaultCellStyle.SelectionForeColor = Get-SelectorColor -Name 'Text'
        $headerRow.DefaultCellStyle.Font = $groupFont
        $headerRow.Cells[0].Value = $false
        $headerRow.Cells[1].Value = Get-SelectorGroupHeaderText -Group $group -Collapsed $true
        $headerRow.Cells[1].ToolTipText = [string]$group.Description
        $headerRow.Cells[2].Value = [string]$group.DecisionText
        if (-not $selectableGroup) {
            $headerRow.Cells[2].Style.ForeColor = Get-SelectorColor -Name 'ReviewText'
            $headerRow.Cells[2].Style.SelectionForeColor = Get-SelectorColor -Name 'ReviewText'
        }

        foreach ($finding in @($group.Findings)) {
            $rowIndex = $grid.Rows.Add()
            $row = $grid.Rows[$rowIndex]
            $selectable = [bool](Test-W360FindingDeletable -Finding $finding -Effective $effective)
            $id = if ($selectable) { ([string]$finding.SelectionId).Trim().ToUpperInvariant() } else { '' }
            $status = Get-W360FindingStatus -Finding $finding -Effective $effective
            $row.Tag = [pscustomobject]@{
                Type        = 'Finding'
                Finding     = $finding
                GroupInfo   = $info
                Selectable  = $selectable
                SelectionId = $id
            }
            $row.Cells[0].Value = ($selectable -and $selection.ContainsKey($id))
            $row.Cells[1].Value = Get-W360FindingDisplayName -Finding $finding
            $row.Cells[1].Style.Padding = New-Object Windows.Forms.Padding($indent, 0, 0, 0)
            $row.Cells[2].Value = $status.Text
            $row.Cells[2].ToolTipText = $status.Explanation
            if (-not $selectable) {
                $row.DefaultCellStyle.BackColor = Get-SelectorColor -Name 'ReviewBack'
                $row.DefaultCellStyle.ForeColor = Get-SelectorColor -Name 'ReviewText'
                $row.DefaultCellStyle.SelectionForeColor = Get-SelectorColor -Name 'ReviewText'
                $row.Cells[0].ToolTipText = $status.Text
            }
            # Products start collapsed: the product row alone answers "delete or keep".
            $row.Visible = $false
            $info.RowIndexes.Add($rowIndex)
        }
    }
    $grid.Tag = $page
    $page.Grid = $grid
    $page.Data['Groups'] = $groupInfos

    $grid.Add_CellPainting({
            param($sender, $paintInfo)
            Invoke-SelectorGridCellPainting -Grid $sender -PaintInfo $paintInfo
        })
    $grid.Add_CellMouseClick({
            param($sender, $clickInfo)
            Invoke-SelectorUiAction -SelectorAction {
                if ($clickInfo.RowIndex -lt 0 -or $clickInfo.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
                Invoke-SelectorScanGridActivate -Page $sender.Tag -RowIndex $clickInfo.RowIndex -ColumnIndex $clickInfo.ColumnIndex
            }
        })
    $grid.Add_KeyDown({
            param($sender, $keyInfo)
            Invoke-SelectorUiAction -SelectorAction { Invoke-SelectorScanGridKey -Page $sender.Tag -KeyInfo $keyInfo }
        })
    $grid.Add_CurrentCellChanged({
            param($sender, $changeInfo)
            try {
                if ($sender.ContainsFocus -and $null -ne $sender.CurrentRow) {
                    Update-SelectorScanDetail -Page $sender.Tag -RowIndex $sender.CurrentRow.Index
                }
            }
            catch {}
        })
    [void](Add-SelectorTableRow -Table $page.Root -Control $grid -SizeType Percent -Height 100)

    [void](Add-SelectorDetailArea -Page $page -BoxName 'FindingDetail' -Placeholder (Get-SelectorText -Key 'Gui.Scan.DetailPlaceholder'))

    # The counter and the note are one line each (the full text is in the tooltip) so the list keeps its height.
    $page.Data['Counter'] = $null
    $page.Data['SelectionNote'] = $null
    if ($hasDeletable) {
        $counter = New-SelectorLabel -Text '' -Bold -Name 'SelectionCounter'
        $counter.AutoSize = $false
        $counter.AutoEllipsis = $true
        $counter.Height = [int](Get-SelectorFont -Bold).Height + 6
        [void](Add-SelectorTableRow -Table $page.Root -Control $counter)
        $page.Data['Counter'] = $counter
        $note = New-SelectorLabel -Text '' -Color 'Warning' -Name 'SelectionNote'
        $note.AutoSize = $false
        $note.AutoEllipsis = $true
        $note.Height = [int](Get-SelectorFont).Height + 6
        $note.Visible = $false
        [void](Add-SelectorTableRow -Table $page.Root -Control $note)
        $page.Data['SelectionNote'] = $note
    }

    $helpHandler = { Invoke-SelectorUiAction -SelectorAction { Show-SelectorHelpSummaryForPage -Page $script:SelectorApp.Shell.CurrentPage } }
    $closeHandler = { Invoke-SelectorUiAction -SelectorAction { Close-SelectorApp } }
    if ($hasDeletable) {
        [void](Add-SelectorPageButton -Page $page -Name 'CleanSelected' -Text (Get-SelectorText -Key 'Ui.Button.CleanSelected') -Style Danger -OnClick {
                Invoke-SelectorUiAction -SelectorAction { Invoke-SelectorCleanRequest -Page $script:SelectorApp.Shell.CurrentPage }
            })
        # Ticks only deletable items that are safe together (shrink-only); the plan and confirm dialogs still follow.
        [void](Add-SelectorPageButton -Page $page -Name 'SelectAllDeletable' -Text (Get-SelectorText -Key 'Ui.Button.SelectAllDeletable') -OnClick {
                Invoke-SelectorUiAction -SelectorAction { [void](Invoke-SelectorSelectAllDeletable -Page $script:SelectorApp.Shell.CurrentPage) }
            })
        [void](Add-SelectorPageButton -Page $page -Name 'ClearSelection' -Text (Get-SelectorText -Key 'Ui.Button.ClearSelection') -OnClick {
                Invoke-SelectorUiAction -SelectorAction { Clear-SelectorSelection -Page $script:SelectorApp.Shell.CurrentPage }
            })
        [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick $helpHandler)
        [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick $closeHandler)
    }
    else {
        [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -Style Primary -OnClick $closeHandler)
        [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick $helpHandler)
    }
    # Enter never starts a deletion: the page has no default button.
    $page.AcceptButton = $null
    $page.InitialFocus = $grid
    Update-SelectorScanSelectionView -Page $page
    return (Complete-SelectorPage -Page $page)
}

function Get-SelectorCheckBoxState {
    param([AllowEmptyString()][string]$CheckState)

    switch ($CheckState) {
        'Checked' { return [Windows.Forms.VisualStyles.CheckBoxState]::CheckedNormal }
        'Indeterminate' { return [Windows.Forms.VisualStyles.CheckBoxState]::MixedNormal }
        'Unchecked' { return [Windows.Forms.VisualStyles.CheckBoxState]::UncheckedNormal }
    }
    return [Windows.Forms.VisualStyles.CheckBoxState]::UncheckedDisabled
}

function Invoke-SelectorGridCellPainting {
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [Parameter(Mandatory = $true)][object]$PaintInfo
    )

    try {
        if ($PaintInfo.RowIndex -lt 0 -or $PaintInfo.ColumnIndex -lt 0) { return }
        $info = $Grid.Rows[$PaintInfo.RowIndex].Tag
        if ($null -eq $info) { return }
        $isGroup = [string]$info.Type -eq 'Group'
        $hasCheck = $Grid.Columns[0].Name -eq 'Select'
        $glyphState = $null
        $spanCell = $false
        if ($hasCheck) {
            if ($PaintInfo.ColumnIndex -ne 0) { return }
            if ($isGroup) { $glyphState = Get-SelectorCheckBoxState -CheckState ([string]$info.CheckState) }
            elseif (-not [bool]$info.Selectable) { $glyphState = [Windows.Forms.VisualStyles.CheckBoxState]::UncheckedDisabled }
            else { return }
        }
        elseif ($isGroup) { $spanCell = $true }
        else { return }

        $bounds = $PaintInfo.CellBounds
        $selected = ($PaintInfo.State -band [Windows.Forms.DataGridViewElementStates]::Selected) -ne 0
        $backColor = if ($selected) { $PaintInfo.CellStyle.SelectionBackColor } else { $PaintInfo.CellStyle.BackColor }
        $brush = New-Object Drawing.SolidBrush($backColor)
        $pen = New-Object Drawing.Pen($Grid.GridColor)
        try {
            $PaintInfo.Graphics.FillRectangle($brush, $bounds)
            $PaintInfo.Graphics.DrawLine($pen, $bounds.Left, ($bounds.Bottom - 1), ($bounds.Right - 1), ($bounds.Bottom - 1))
            if ($null -ne $glyphState) {
                $glyph = [Windows.Forms.CheckBoxRenderer]::GetGlyphSize($PaintInfo.Graphics, $glyphState)
                $point = New-Object Drawing.Point(
                    ($bounds.Left + [int](($bounds.Width - $glyph.Width) / 2)),
                    ($bounds.Top + [int](($bounds.Height - $glyph.Height) / 2)))
                [Windows.Forms.CheckBoxRenderer]::DrawCheckBox($PaintInfo.Graphics, $point, $glyphState)
            }
        }
        finally {
            $brush.Dispose()
            $pen.Dispose()
        }
        $PaintInfo.Handled = $true
    }
    catch {}
}

# Verify section headers span the whole row: the cells are blank-painted and the title is drawn here.
function Invoke-SelectorGridRowPostPaint {
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [Parameter(Mandatory = $true)][object]$PaintInfo,
        [int]$FirstTextColumn = 0
    )

    try {
        $row = $Grid.Rows[$PaintInfo.RowIndex]
        $info = $row.Tag
        if ($null -eq $info -or [string]$info.Type -ne 'Group') { return }
        $cellRect = $Grid.GetCellDisplayRectangle($FirstTextColumn, $PaintInfo.RowIndex, $false)
        $left = if ($cellRect.Width -gt 0) { $cellRect.Left } else { $PaintInfo.RowBounds.Left }
        $rect = New-Object Drawing.Rectangle(($left + 4), $PaintInfo.RowBounds.Top,
            [Math]::Max(0, ($Grid.DisplayRectangle.Right - $left - 8)), $PaintInfo.RowBounds.Height)
        $flags = [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::VerticalCenter -bor
        [Windows.Forms.TextFormatFlags]::SingleLine -bor [Windows.Forms.TextFormatFlags]::EndEllipsis -bor
        [Windows.Forms.TextFormatFlags]::NoPrefix
        [Windows.Forms.TextRenderer]::DrawText($PaintInfo.Graphics, [string]$row.Cells[$FirstTextColumn].Value,
            (Get-SelectorFont -Bold), $rect, (Get-SelectorColor -Name 'Text'), $flags)
    }
    catch {}
}

function Invoke-SelectorScanGridActivate {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex,
        [int]$ColumnIndex
    )

    if ($RowIndex -lt 0 -or $RowIndex -ge $Page.Grid.Rows.Count) { return }
    $info = $Page.Grid.Rows[$RowIndex].Tag
    if ($null -eq $info) { return }
    if ([string]$info.Type -eq 'Group') {
        if ($ColumnIndex -eq 0) { [void](Switch-SelectorGroupSelection -Page $Page -RowIndex $RowIndex) }
        else { [void](Switch-SelectorGroupCollapse -Page $Page -RowIndex $RowIndex) }
    }
    elseif ($ColumnIndex -eq 0) {
        [void](Switch-SelectorFindingSelection -Page $Page -RowIndex $RowIndex)
    }
    Update-SelectorScanDetail -Page $Page -RowIndex $RowIndex
}

# Space toggles the current row (a product row toggles the product); Left/Right collapse or expand a product.
# Enter is not bound: the grid consumes it, and the page has no default button.
function Invoke-SelectorScanGridKey {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][object]$KeyInfo
    )

    $grid = $Page.Grid
    if ($null -eq $grid.CurrentRow -or $KeyInfo.Modifiers -ne [Windows.Forms.Keys]::None) { return }
    $rowIndex = $grid.CurrentRow.Index
    $info = $grid.Rows[$rowIndex].Tag
    if ($null -eq $info) { return }
    $isGroup = [string]$info.Type -eq 'Group'
    switch ($KeyInfo.KeyCode) {
        ([Windows.Forms.Keys]::Space) {
            $KeyInfo.Handled = $true
            Invoke-SelectorScanGridActivate -Page $Page -RowIndex $rowIndex -ColumnIndex 0
        }
        ([Windows.Forms.Keys]::Left) {
            if ($isGroup) {
                $KeyInfo.Handled = $true
                if (-not [bool]$info.Collapsed) { [void](Switch-SelectorGroupCollapse -Page $Page -RowIndex $rowIndex) }
            }
        }
        ([Windows.Forms.Keys]::Right) {
            if ($isGroup) {
                $KeyInfo.Handled = $true
                if ([bool]$info.Collapsed) { [void](Switch-SelectorGroupCollapse -Page $Page -RowIndex $rowIndex) }
            }
        }
    }
}

function Update-SelectorScanDetail {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex
    )

    if ($RowIndex -lt 0 -or $RowIndex -ge $Page.Grid.Rows.Count) { return }
    $info = $Page.Grid.Rows[$RowIndex].Tag
    if ($null -eq $info) { return }
    if ([string]$info.Type -eq 'Group') {
        Set-SelectorBoxText -Box $Page.DetailBox -Text (Get-SelectorGroupDetailText -Group $info.Group)
        Set-SelectorInfoRow -Page $Page -RowIndex -1
    }
    else {
        Set-SelectorBoxText -Box $Page.DetailBox -Text (Get-SelectorFindingDetailText -Finding $info.Finding -Effective $Page.Data['Effective'])
        Set-SelectorInfoRow -Page $Page -RowIndex $RowIndex
    }
}

function Get-SelectorSelectedIds {
    param([Parameter(Mandatory = $true)][object]$Page)
    return [string[]]@($Page.Data['Selection'].Keys)
}

function Set-SelectorSelectionNote {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [AllowEmptyString()][string]$Text = ''
    )

    $note = $Page.Data['SelectionNote']
    if ($null -eq $note) { return }
    $show = -not [string]::IsNullOrWhiteSpace($Text)
    $note.Text = $Text
    $note.AccessibleName = $Text
    $tip = $Page.Data['SelectionNoteTip']
    if ($null -ne $tip) { try { $tip.SetToolTip($note, $Text) } catch {} }
    $note.Visible = $show
    # The description area gives up the note's height (down to one line) so the list does not shrink.
    Update-SelectorDetailAreaFit -Page $Page
}

function Switch-SelectorFindingSelection {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex
    )

    $info = $Page.Grid.Rows[$RowIndex].Tag
    if ($null -eq $info -or [string]$info.Type -ne 'Finding' -or -not [bool]$info.Selectable) { return $false }
    # A single row the user clicks is never shrunk here; the selection check explains problems before deleting.
    $selection = $Page.Data['Selection']
    $id = [string]$info.SelectionId
    if ($selection.ContainsKey($id)) { [void]$selection.Remove($id) }
    else { $selection[$id] = $info.Finding }
    Update-SelectorScanSelectionView -Page $Page
    Set-SelectorSelectionNote -Page $Page
    return $true
}

# Product row checkbox. It adds only the product's deletable items that are safe to add together with the
# current selection (Get-W360DeletableSelection shrinks, never grows); a second click unticks the product.
function Switch-SelectorGroupSelection {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex
    )

    $info = $Page.Grid.Rows[$RowIndex].Tag
    if ($null -eq $info -or [string]$info.Type -ne 'Group') { return $false }
    $groupIds = @($info.Group.SelectableIds)
    if ($groupIds.Count -eq 0) { return $false }
    $selection = $Page.Data['Selection']
    $selectedInGroup = 0
    foreach ($id in $groupIds) { if ($selection.ContainsKey([string]$id)) { $selectedInGroup++ } }
    if ($selectedInGroup -eq $groupIds.Count) {
        # A fully ticked product unticks at once; nothing needs to be checked for that.
        foreach ($id in $groupIds) { [void]$selection.Remove([string]$id) }
        Update-SelectorScanSelectionView -Page $Page
        Set-SelectorSelectionNote -Page $Page
        return $true
    }
    $probe = Invoke-SelectorWithWaitCursor -Action {
        Get-W360DeletableSelection -Findings @(Get-W360ArrayProperty -Object $Page.Outcome -Name 'Findings') `
            -CandidateIds ([string[]]$groupIds) -SelectedIds (Get-SelectorSelectedIds -Page $Page)
    }
    $addedCount = @($probe.AddedIds).Count
    $anySelected = $selectedInGroup -gt 0

    if ($addedCount -eq 0 -and $anySelected) {
        # Nothing more can be added safely, so the click unticks the whole product (never locks up).
        foreach ($id in $groupIds) { [void]$selection.Remove([string]$id) }
        Update-SelectorScanSelectionView -Page $Page
        Set-SelectorSelectionNote -Page $Page
        return $true
    }
    if ($addedCount -gt 0) {
        Set-SelectorSelectionDictionary -Page $Page -Ids @($probe.Ids)
    }
    Update-SelectorScanSelectionView -Page $Page
    Set-SelectorSkippedNote -Page $Page -Removed @($probe.Removed)
    return $true
}

# "Select everything that can be deleted": the same shrink-only helper as the product checkbox, over every
# deletable item. Items that cannot be deleted are never ticked; already ticked items stay ticked.
function Invoke-SelectorSelectAllDeletable {
    param([Parameter(Mandatory = $true)][object]$Page)

    $selectableById = $Page.Data['SelectableById']
    if ($null -eq $selectableById -or $selectableById.Count -eq 0) { return $false }
    $probe = Invoke-SelectorWithWaitCursor -Action {
        Get-W360DeletableSelection -Findings @(Get-W360ArrayProperty -Object $Page.Outcome -Name 'Findings') `
            -CandidateIds ([string[]]@($selectableById.Keys)) -SelectedIds (Get-SelectorSelectedIds -Page $Page)
    }
    Set-SelectorSelectionDictionary -Page $Page -Ids @($probe.Ids)
    Update-SelectorScanSelectionView -Page $Page
    Set-SelectorSkippedNote -Page $Page -Removed @($probe.Removed)
    return $true
}

# Runs a selection check with the wait cursor, so clicks made while it runs are not taken as new choices.
function Invoke-SelectorWithWaitCursor {
    param([Parameter(Mandatory = $true)][scriptblock]$Action)

    $form = $null
    $previous = $null
    try {
        if ($null -ne $script:SelectorApp -and -not $script:SelectorApp.Form.IsDisposed) {
            $form = $script:SelectorApp.Form
            $previous = $form.Cursor
            $form.UseWaitCursor = $true
            $form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        }
    }
    catch { $form = $null }
    try { return (& $Action) }
    finally {
        if ($null -ne $form) {
            try {
                $form.UseWaitCursor = $false
                $form.Cursor = $previous
            }
            catch {}
        }
    }
}

function Set-SelectorSkippedNote {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [AllowNull()][AllowEmptyCollection()][object[]]$Removed
    )

    $items = @(Get-W360Items -Value $Removed)
    if ($items.Count -eq 0) {
        Set-SelectorSelectionNote -Page $Page
        return
    }
    if ($items.Count -eq 1) {
        Set-SelectorSelectionNote -Page $Page -Text (Get-SelectorText -Key 'Ui.Select.SkippedNoteOne' -Arguments @(
                [string]$items[0].DisplayName, [string]$items[0].ReasonText))
        return
    }
    Set-SelectorSelectionNote -Page $Page -Text (Get-SelectorText -Key 'Ui.Select.SkippedNote' -Arguments @(
            $items.Count, [string]$items[0].DisplayName, [string]$items[0].ReasonText))
}

function Switch-SelectorGroupCollapse {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex
    )

    $grid = $Page.Grid
    $info = $grid.Rows[$RowIndex].Tag
    if ($null -eq $info -or [string]$info.Type -ne 'Group') { return $false }
    $collapse = -not [bool]$info.Collapsed
    if ($collapse -and $null -ne $grid.CurrentCell -and $info.RowIndexes.Contains($grid.CurrentCell.RowIndex)) {
        $grid.CurrentCell = $grid.Rows[$info.HeaderIndex].Cells[1]
    }
    foreach ($childIndex in $info.RowIndexes) { $grid.Rows[$childIndex].Visible = -not $collapse }
    $info.Collapsed = $collapse
    $grid.Rows[$info.HeaderIndex].Cells[1].Value = Get-SelectorGroupHeaderText -Group $info.Group -Collapsed $collapse
    $grid.InvalidateRow($info.HeaderIndex)
    return $true
}

function Set-SelectorSelectionDictionary {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [AllowNull()][AllowEmptyCollection()][object[]]$Ids
    )

    $selection = $Page.Data['Selection']
    $selectableById = $Page.Data['SelectableById']
    $selection.Clear()
    foreach ($rawId in @(Get-W360Items -Value $Ids)) {
        $id = ([string]$rawId).Trim().ToUpperInvariant()
        if ($selectableById.ContainsKey($id) -and -not $selection.ContainsKey($id)) { $selection[$id] = $selectableById[$id] }
    }
}

function Set-SelectorSelectedIds {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [AllowNull()][AllowEmptyCollection()][string[]]$Ids
    )

    Set-SelectorSelectionDictionary -Page $Page -Ids $Ids
    Update-SelectorScanSelectionView -Page $Page
    Set-SelectorSelectionNote -Page $Page
}

function Clear-SelectorSelection {
    param([Parameter(Mandatory = $true)][object]$Page)

    $Page.Data['Selection'].Clear()
    Update-SelectorScanSelectionView -Page $Page
    Set-SelectorSelectionNote -Page $Page
}

function Get-SelectorGroupCheckState {
    param(
        [Parameter(Mandatory = $true)][object]$GroupInfo,
        [Parameter(Mandatory = $true)][object]$Selection
    )

    $ids = @($GroupInfo.Group.SelectableIds)
    if ($ids.Count -eq 0) { return 'Disabled' }
    $selected = 0
    foreach ($id in $ids) { if ($Selection.ContainsKey([string]$id)) { $selected++ } }
    if ($selected -eq 0) { return 'Unchecked' }
    if ($selected -eq $ids.Count) { return 'Checked' }
    return 'Indeterminate'
}

function Update-SelectorScanSelectionView {
    param([Parameter(Mandatory = $true)][object]$Page)

    $grid = $Page.Grid
    $selection = $Page.Data['Selection']
    $willDelete = Get-SelectorText -Key 'Ui.Row.WillDelete'
    $canDelete = Get-SelectorText -Key 'Status.AwaitingChoice.Text'
    $normalFont = Get-SelectorFont
    $boldFont = Get-SelectorFont -Bold
    foreach ($row in $grid.Rows) {
        $info = $row.Tag
        if ($null -eq $info -or [string]$info.Type -ne 'Finding' -or -not [bool]$info.Selectable) { continue }
        $checked = $selection.ContainsKey([string]$info.SelectionId)
        if ([bool]$row.Cells[0].Value -ne $checked) { $row.Cells[0].Value = $checked }
        $decisionCell = $row.Cells[2]
        $decision = if ($checked) { $willDelete } else { $canDelete }
        if ([string]$decisionCell.Value -cne $decision) { $decisionCell.Value = $decision }
        $colorName = if ($checked) { 'Danger' } else { 'Text' }
        $decisionCell.Style.ForeColor = Get-SelectorColor -Name $colorName
        $decisionCell.Style.SelectionForeColor = Get-SelectorColor -Name $colorName
        $decisionCell.Style.Font = $(if ($checked) { $boldFont } else { $normalFont })
    }
    foreach ($groupInfo in @($Page.Data['Groups'])) {
        $state = Get-SelectorGroupCheckState -GroupInfo $groupInfo -Selection $selection
        $groupInfo.CheckState = $state
        # The cell value stays a plain bool (true only when every deletable item is ticked); the mixed state is painted.
        $headerCell = $grid.Rows[$groupInfo.HeaderIndex].Cells[0]
        $checked = $state -eq 'Checked'
        if ([bool]$headerCell.Value -ne $checked) { $headerCell.Value = $checked }
        try { $grid.InvalidateCell($headerCell) } catch {}
    }
    $count = $selection.Count
    $counter = $Page.Data['Counter']
    if ($null -ne $counter) {
        if ($count -gt $script:SelectorMaxSelected) {
            $counter.Text = Get-SelectorText -Key 'Ui.Scan.TooMany' -Arguments @($count, $script:SelectorMaxSelected)
            $counter.ForeColor = Get-SelectorColor -Name 'Error'
        }
        else {
            $counter.Text = Get-SelectorText -Key 'Ui.Scan.SelectionCounter' -Arguments @($count)
            $counter.ForeColor = Get-SelectorColor -Name 'Text'
        }
        $counter.AccessibleName = $counter.Text
        $counterTip = $Page.Data['SelectionNoteTip']
        if ($null -ne $counterTip) { try { $counterTip.SetToolTip($counter, $counter.Text) } catch {} }
    }
    if ($Page.Buttons.Contains('CleanSelected')) { $Page.Buttons['CleanSelected'].Enabled = ($count -ge 1) }
    if ($Page.Buttons.Contains('SelectAllDeletable')) { $Page.Buttons['SelectAllDeletable'].Enabled = ($Page.Data['SelectableById'].Count -gt 0) }
    if ($Page.Buttons.Contains('ClearSelection')) { $Page.Buttons['ClearSelection'].Enabled = ($count -ge 1) }

    # "Unticked items are not deleted" is never said while an uninstaller that came with 360 is ticked: it may
    # remove unticked parts of its product.
    if ($null -ne $Page.DetailLabel -and [bool]$Page.Data['HasDeletable']) {
        $vendorSelected = $false
        foreach ($selectedFinding in @($selection.Values)) {
            if ((Get-W360StringProperty -Object $selectedFinding -Name 'Kind') -eq 'VendorUninstaller' -or
                (Get-W360StringProperty -Object $selectedFinding -Name 'RemovalType') -eq 'VendorUninstaller') { $vendorSelected = $true; break }
        }
        $Page.Data['VendorSelected'] = $vendorSelected
        $detailKey = if ($vendorSelected) { 'Scan.Findings.DetailVendor' } else { 'Scan.Findings.Detail' }
        $detailText = Get-SelectorText -Key $detailKey
        if ([string]$Page.DetailLabel.Text -cne $detailText) {
            $Page.DetailLabel.Text = $detailText
            $Page.DetailLabel.ForeColor = Get-SelectorColor -Name $(if ($vendorSelected) { 'Warning' } else { 'Text' })
        }
    }
}

# The items the selection-adjust dialog offers to add: the child and folder items its problems name, limited to items
# that can be ticked on the page (DeletableIds: the effectively deletable ones) and not selected yet, in problem order.
# Adding them is still the user's explicit click on "AddChildren".
function Get-SelectorPlanAddIds {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [AllowNull()][AllowEmptyCollection()][string[]]$DeletableIds
    )

    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($rawId in @(Get-W360Items -Value $DeletableIds)) { [void]$allowed.Add(([string]$rawId).Trim()) }
    $selectedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($selectedId in @(Get-W360ArrayProperty -Object $Plan -Name 'SelectedIds')) { [void]$selectedIds.Add(([string]$selectedId).Trim()) }
    $result = New-Object System.Collections.Generic.List[string]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($problem in @(Get-W360ArrayProperty -Object $Plan -Name 'Problems')) {
        foreach ($rawId in @(Get-W360ArrayProperty -Object $problem -Name 'AddSelectionIds')) {
            $id = ([string]$rawId).Trim().ToUpperInvariant()
            if ($id -notmatch '^[0-9A-F]{64}$' -or -not $allowed.Contains($id) -or $selectedIds.Contains($id)) { continue }
            if ($seen.Add($id)) { $result.Add($id) }
        }
    }
    return [string[]]$result.ToArray()
}

# The selection after the user clicked "AddChildren": SelectedIds plus exactly the items the dialog offered
# (Get-SelectorPlanAddIds with the page's tickable IDs). Nothing that cannot be ticked on the page is ever added.
function Add-SelectorPlanChildren {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [Parameter(Mandatory = $true)][object]$Plan,
        [AllowNull()][AllowEmptyCollection()][string[]]$SelectedIds
    )

    $offered = [pscustomobject]@{
        AddSelectionIds = [string[]]@(Get-SelectorPlanAddIds -Plan $Plan -DeletableIds ([string[]]@($Page.Data['SelectableById'].Keys)))
    }
    return [string[]](Add-W360PlanSelections -SelectedIds $SelectedIds -Problem $offered)
}

function New-SelectorPlanProblemDialog {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        # The IDs that can be ticked on the scan page (its SelectableById keys); only these are ever offered for adding.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$DeletableIds
    )

    $dialog = New-SelectorDialogShell -Title (Get-SelectorText -Key 'Ui.Plan.Title') -Width 700 -Height 500
    $dialog.Kind = 'PlanDialog'
    $dialog.Data['Plan'] = $Plan
    Add-SelectorPageHeadline -Page $dialog -Headline (Get-SelectorText -Key 'Ui.Plan.Title') -Detail (Get-SelectorText -Key 'Gui.Plan.Intro') -Color 'Warning' -FontSize 13

    # Identical problems (the same message and advice) are one numbered line with a count.
    $entries = New-Object System.Collections.ArrayList
    $entryByText = @{}
    $addIds = @(Get-SelectorPlanAddIds -Plan $Plan -DeletableIds $DeletableIds)
    foreach ($problem in @(Get-W360ArrayProperty -Object $Plan -Name 'Problems')) {
        $message = Get-W360StringProperty -Object $problem -Name 'Message'
        $resolution = Get-W360StringProperty -Object $problem -Name 'Resolution'
        $textKey = $message + [char]0 + $resolution
        if ($entryByText.ContainsKey($textKey)) { $entryByText[$textKey].Count++ }
        else {
            $entry = [pscustomobject]@{ Message = $message; Resolution = $resolution; Count = 1 }
            $entryByText[$textKey] = $entry
            [void]$entries.Add($entry)
        }
    }
    $lines = New-Object System.Collections.Generic.List[string]
    $number = 1
    # Lines are "1. problem" and "   What to do: advice", with a blank line between problems.
    foreach ($entry in $entries) {
        $message = if ([int]$entry.Count -gt 1) { Get-SelectorText -Key 'Gui.Plan.Repeated' -Arguments @($entry.Message, $entry.Count) } else { $entry.Message }
        $lines.Add(('{0}. {1}' -f $number, $message))
        $lines.Add(('   ' + (Get-SelectorText -Key 'Gui.Plan.ResolutionLine' -Arguments @($entry.Resolution))))
        $lines.Add('')
        $number++
    }
    $box = New-SelectorReadOnlyTextBox -Text ($lines.ToArray() -join "`r`n")
    $box.Name = 'ProblemList'
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $box -SizeType Percent -Height 100)
    $dialog.DetailBox = $box

    $form = $dialog.Data['Form']
    $canAdd = $addIds.Count -gt 0
    $dialog.Data['CanAdd'] = $canAdd
    $dialog.Data['AddCount'] = $addIds.Count
    $dialog.Data['AddIds'] = [string[]]$addIds
    if ($canAdd) {
        # Adding is still an explicit click; it adds exactly the items the plan names that can be ticked.
        $add = Add-SelectorPageButton -Page $dialog -Name 'AddChildren' -Text (Get-SelectorText -Key 'Ui.Button.AddChildren' -Arguments @($addIds.Count)) -Style Primary
        $add.DialogResult = [Windows.Forms.DialogResult]::Yes
    }
    $back = Add-SelectorPageButton -Page $dialog -Name 'BackToEdit' -Text (Get-SelectorText -Key 'Ui.Button.BackToEdit') -Style $(if ($canAdd) { 'Normal' } else { 'Primary' })
    $back.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $back
    $form.CancelButton = $back
    $dialog.AcceptButton = $back
    $dialog.InitialFocus = $back
    return (Complete-SelectorPage -Page $dialog)
}

# The item list of the confirmation dialog. The wording lives in the shared library (Get-W360ConfirmText), so the
# agent route (scripts/Show-360Summary.ps1) shows exactly the same list.
function Get-SelectorConfirmText {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [AllowNull()][AllowEmptyCollection()][object[]]$AllFindings,
        # The scan page's effectively deletable set, so it is not worked out again.
        [AllowNull()][object]$Effective
    )

    return (Get-W360ConfirmText -Plan $Plan -AllFindings $AllFindings -KeptLineLimit $script:SelectorKeptLineLimit -Effective $Effective)
}

function New-SelectorConfirmDialog {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        # Every finding of the check (selected, not selected and kept); used for the "kept" list.
        [AllowNull()][AllowEmptyCollection()][object[]]$AllFindings = @(),
        [AllowNull()][object]$Effective
    )

    $title = Get-SelectorText -Key 'Ui.Confirm.Title'
    $dialog = New-SelectorDialogShell -Title $title -Width 780 -Height 660
    $dialog.Kind = 'ConfirmDialog'
    $dialog.Data['Plan'] = $Plan
    Add-SelectorPageHeadline -Page $dialog -Headline $title -Color 'Danger' -FontSize 14

    $box = New-SelectorReadOnlyTextBox -Text (Get-SelectorConfirmText -Plan $Plan -AllFindings $AllFindings -Effective $Effective)
    $box.Name = 'ConfirmItems'
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $box -SizeType Percent -Height 100)
    $dialog.DetailBox = $box

    $permanent = New-SelectorLabel -Text (Get-SelectorText -Key 'Ui.Confirm.PermanentDelete') -FontSize 10.5 -Bold -Color 'Danger' -Name 'PermanentDelete'
    $permanent.Margin = New-Object Windows.Forms.Padding(3, 8, 3, 3)
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $permanent)
    $dialog.Data['VendorWarning'] = $null
    if ([bool](Get-W360PropertyValue -Object $Plan -Name 'VendorUninstallerSelected')) {
        $vendor = New-SelectorLabel -Text ([string][char]0x26A0 + ' ' + (Get-SelectorText -Key 'Ui.Confirm.VendorWarning')) -Bold -Color 'Danger' -Name 'VendorWarning'
        [void](Add-SelectorTableRow -Table $dialog.Root -Control $vendor)
        $dialog.Data['VendorWarning'] = $vendor
    }
    $notes = New-SelectorLabel -Text (Join-SelectorLines -Lines @((Get-SelectorText -Key 'Ui.Confirm.CloseApps'), (Get-SelectorText -Key 'Ui.Confirm.Uac'))) -Bold -Name 'ConfirmNotes'
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $notes)

    # "Cancel" is first, the default, the Enter key and the Esc key; "Delete" needs its own click.
    $form = $dialog.Data['Form']
    $back = Add-SelectorPageButton -Page $dialog -Name 'BackToEdit' -Text (Get-SelectorText -Key 'Ui.Button.Cancel') -Style Primary
    $back.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $confirm = Add-SelectorPageButton -Page $dialog -Name 'ConfirmRemove' -Text (Get-SelectorText -Key 'Ui.Button.ConfirmRemove') -Style Danger
    $confirm.DialogResult = [Windows.Forms.DialogResult]::OK
    $dialog.PrimaryButton = $back
    $form.AcceptButton = $back
    $form.CancelButton = $back
    $dialog.AcceptButton = $back
    $dialog.InitialFocus = $back
    return (Complete-SelectorPage -Page $dialog)
}

function New-SelectorScrollContent {
    $scroll = New-Object Windows.Forms.Panel
    $scroll.Dock = [Windows.Forms.DockStyle]::Fill
    $scroll.AutoScroll = $true
    $scroll.Margin = New-Object Windows.Forms.Padding(0)
    $scroll.Padding = New-Object Windows.Forms.Padding(0)
    $scroll.Name = 'ScrollContent'

    $content = New-SelectorTable -Columns 1 -AutoSizeTable
    $content.Dock = [Windows.Forms.DockStyle]::Top
    $content.Name = 'Content'
    [void]$content.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    $scroll.Controls.Add($content)
    return [pscustomobject]@{ Scroll = $scroll; Content = $content }
}

function Get-SelectorRemoveStatLines {
    param([AllowNull()][object]$Stats)

    if ($null -eq $Stats) { return @() }
    $pairs = @(
        @('Stats.Selected', 'Selected'), @('Stats.Preserved', 'Preserved'), @('Stats.FilesRemoved', 'FilesRemoved'),
        @('Stats.DirectoriesRemoved', 'DirectoriesRemoved'), @('Stats.LogicalSize', 'LogicalSize'),
        @('Stats.ServicesRemoved', 'ServicesRemoved'), @('Stats.ServicesPendingRemoval', 'ServicesPendingRemoval'),
        @('Stats.ScheduledTasksRemoved', 'ScheduledTasksRemoved'), @('Stats.RegistryItemsRemoved', 'RegistryItemsRemoved'),
        @('Stats.ProcessesStopped', 'ProcessesStopped'), @('Stats.VendorUninstallersSucceeded', 'VendorUninstallersSucceeded'),
        @('Stats.SkippedActions', 'SkippedActions'), @('Stats.FailedActions', 'FailedActions'), @('Stats.PendingActions', 'PendingActions')
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($pair in $pairs) {
        $value = Get-W360StringProperty -Object $Stats -Name $pair[1]
        if ($pair[1] -eq 'LogicalSize') {
            if ([string]::IsNullOrWhiteSpace($value)) { $value = Get-SelectorText -Key 'Common.NotRecorded' }
            $value = $value + ' (' + (Get-SelectorText -Key 'Stats.LogicalSizeNote') + ')'
        }
        $lines.Add((Get-SelectorText -Key 'Gui.Remove.StatLine' -Arguments @((Get-SelectorText -Key $pair[0]), $value)))
    }
    $note = Get-W360StringProperty -Object $Stats -Name 'PathAccountingNote'
    if (-not [string]::IsNullOrWhiteSpace($note)) { $lines.Add(([string][char]0x26A0 + ' ' + $note)) }
    return $lines.ToArray()
}

function New-SelectorRemoveResultPage {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    $state = Get-SelectorOutcomeString -Outcome $Outcome -Name 'State'
    $page = New-SelectorPageObject -Kind 'RemoveResult'
    $page.Stage = 'Remove'
    $page.Outcome = $Outcome
    $page.ReportPath = Get-SelectorOutcomeString -Outcome $Outcome -Name 'ReportPath'
    Add-SelectorPageHeadline -Page $page -Headline (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Headline') `
        -Color (Get-SelectorOutcomeColor -Outcome $Outcome) -FontSize 14

    $scroll = New-SelectorScrollContent
    $content = $scroll.Content
    $detailLabel = New-SelectorLabel -Text (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Detail') -FontSize 10.5 -Name 'Detail'
    [void](Add-SelectorTableRow -Table $content -Control $detailLabel)
    $page.DetailLabel = $detailLabel

    $page.Data['CountsLabel'] = $null
    $countsText = Get-SelectorOutcomeString -Outcome $Outcome -Name 'CountsText'
    if (-not [string]::IsNullOrWhiteSpace($countsText)) {
        $counts = New-SelectorLabel -Text $countsText -Bold -Name 'RemoveCounts'
        $counts.Margin = New-Object Windows.Forms.Padding(3, 8, 3, 3)
        [void](Add-SelectorTableRow -Table $content -Control $counts)
        $page.Data['CountsLabel'] = $counts
    }

    # What to do next comes before the problem list, so it stays visible on small screens.
    $nextLabel = New-SelectorLabel -Text (Get-SelectorNextStepsText -Steps @(Get-W360ArrayProperty -Object $Outcome -Name 'NextSteps')) -Bold -Color 'Info' -Name 'NextSteps'
    $nextLabel.Margin = New-Object Windows.Forms.Padding(3, 10, 3, 3)
    [void](Add-SelectorTableRow -Table $content -Control $nextLabel)
    $page.Data['NextStepsLabel'] = $nextLabel

    $page.Data['ProblemList'] = $null
    $problemLines = @(Get-W360RemoveProblemLines -Outcome $Outcome -Limit $script:SelectorProblemLineLimit)
    if ($problemLines.Count -gt 0) {
        $problemText = Join-SelectorLines -Lines @($problemLines | ForEach-Object { [string][char]0x00B7 + ' ' + $_ })
        $problemLabel = New-SelectorLabel -Text $problemText -Name 'ProblemList'
        $problemLabel.Margin = New-Object Windows.Forms.Padding(3, 10, 3, 3)
        [void](Add-SelectorTableRow -Table $content -Control $problemLabel)
        $page.Data['ProblemList'] = $problemLabel
    }
    [void](Add-SelectorTableRow -Table $page.Root -Control $scroll.Scroll -SizeType Percent -Height 100)
    $page.Data['Scroll'] = $scroll.Scroll

    $hasReport = $null -ne (Get-W360PropertyValue -Object $Outcome -Name 'Report')
    $verifyHandler = { Invoke-SelectorUiAction -SelectorAction { Start-SelectorVerifyAfterRemove -Page $script:SelectorApp.Shell.CurrentPage } }
    $detailsHandler = { Invoke-SelectorUiAction -SelectorAction { Show-SelectorRemoveDetails -Page $script:SelectorApp.Shell.CurrentPage } }
    $helpHandler = { Invoke-SelectorUiAction -SelectorAction { Show-SelectorHelpSummaryForPage -Page $script:SelectorApp.Shell.CurrentPage } }
    $closeHandler = { Invoke-SelectorUiAction -SelectorAction { Close-SelectorApp } }
    $rescanHandler = { Invoke-SelectorUiAction -SelectorAction { Start-SelectorScan } }
    # A run without a readable result offers a new check of the PC, never a check of a deletion it cannot show.
    $buttonSet = if ($state -ceq 'NotStarted' -or -not $hasReport) { 'Rescan' } elseif (@('Completed', 'NeedsRestart') -contains $state) { 'CloseFirst' } else { 'VerifyFirst' }
    switch ($buttonSet) {
        'Rescan' {
            [void](Add-SelectorPageButton -Page $page -Name 'Rescan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -Style Primary -OnClick $rescanHandler)
            [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick $helpHandler)
            [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick $closeHandler)
        }
        'CloseFirst' {
            # Completed needs nothing more now, and checking before a restart would only show items waiting for it.
            [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -Style Primary -OnClick $closeHandler)
            [void](Add-SelectorPageButton -Page $page -Name 'VerifyNow' -Text (Get-SelectorText -Key 'Ui.Button.VerifyNow') -OnClick $verifyHandler)
            $details = Add-SelectorPageButton -Page $page -Name 'ViewDetails' -Text (Get-SelectorText -Key 'Ui.Button.ViewDetails') -OnClick $detailsHandler
            $details.Enabled = $hasReport
            [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick $helpHandler)
        }
        default {
            [void](Add-SelectorPageButton -Page $page -Name 'VerifyNow' -Text (Get-SelectorText -Key 'Ui.Button.VerifyNow') -Style Primary -OnClick $verifyHandler)
            $details = Add-SelectorPageButton -Page $page -Name 'ViewDetails' -Text (Get-SelectorText -Key 'Ui.Button.ViewDetails') -OnClick $detailsHandler
            $details.Enabled = $hasReport
            [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick $helpHandler)
            [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick $closeHandler)
        }
    }
    return (Complete-SelectorPage -Page $page)
}

function Get-SelectorRemoveStatsText {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    $lines = New-Object System.Collections.Generic.List[string]
    $statLines = @(Get-SelectorRemoveStatLines -Stats (Get-W360PropertyValue -Object $Outcome -Name 'Stats'))
    if ($statLines.Count -gt 0) { foreach ($line in $statLines) { $lines.Add([string]$line) } }
    else { $lines.Add((Get-SelectorText -Key 'Gui.Remove.NoStats')) }
    $reportPath = Get-SelectorOutcomeString -Outcome $Outcome -Name 'ReportPath'
    if (-not [string]::IsNullOrWhiteSpace($reportPath)) {
        $lines.Add('')
        $lines.Add((Get-SelectorText -Key 'Help.ReportFile' -Arguments @([IO.Path]::GetFileName($reportPath))))
    }
    $coverage = Get-W360PropertyValue -Object (Get-W360PropertyValue -Object $Outcome -Name 'Report') -Name 'ScanCoverage'
    $issues = @(Get-W360CoverageIssueList -Coverage $coverage)
    if ($issues.Count -gt 0) {
        $lines.Add('')
        $lines.Add((Get-SelectorTextTitle -Key 'Gui.Scan.CoverageTitle'))
        $lines.Add((Get-SelectorCoverageIssueText -Issues $issues))
    }
    return ($lines.ToArray() -join "`r`n")
}

# The Details window of a deletion: statistics, not-fully-checked places, every problem and the full action log.
function New-SelectorRemoveDetailsDialog {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    $title = Get-SelectorText -Key 'Ui.Button.ViewDetails'
    $dialog = New-SelectorDialogShell -Title $title -Width 1000 -Height 640
    $dialog.Kind = 'RemoveDetailsDialog'
    $dialog.Outcome = $Outcome
    $dialog.ReportPath = Get-SelectorOutcomeString -Outcome $Outcome -Name 'ReportPath'
    Add-SelectorPageHeadline -Page $dialog -Headline $title

    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Dock = [Windows.Forms.DockStyle]::Fill
    $tabs.Name = 'DetailTabs'
    $tabs.Font = Get-SelectorFont
    $tabs.Margin = New-Object Windows.Forms.Padding(3, 3, 3, 3)

    $statsPage = New-Object Windows.Forms.TabPage
    $statsPage.Text = Get-SelectorText -Key 'Ui.Remove.Section.Stats'
    $statsPage.Name = 'StatsTab'
    $statsPage.Padding = New-Object Windows.Forms.Padding(4)
    $statsBox = New-SelectorReadOnlyTextBox -Text (Get-SelectorRemoveStatsText -Outcome $Outcome)
    $statsBox.Name = 'StatsText'
    $statsPage.Controls.Add($statsBox)

    $problems = @(Get-W360ArrayProperty -Object $Outcome -Name 'Problems')
    $problemPage = New-Object Windows.Forms.TabPage
    $problemPage.Text = Get-SelectorText -Key 'Gui.Remove.ProblemsTab' -Arguments @($problems.Count)
    $problemPage.Name = 'ProblemsTab'
    $problemPage.Padding = New-Object Windows.Forms.Padding(4)
    $problemGrid = New-SelectorGrid -Name 'ProblemGrid'
    [void](Add-SelectorTextColumn -Grid $problemGrid -Name 'Target' -HeaderText (Get-SelectorText -Key 'Gui.Column.Target') -FillWeight 36)
    [void](Add-SelectorTextColumn -Grid $problemGrid -Name 'Action' -HeaderText (Get-SelectorText -Key 'Gui.Column.Action') -FillWeight 18)
    [void](Add-SelectorTextColumn -Grid $problemGrid -Name 'Result' -HeaderText (Get-SelectorText -Key 'Gui.Column.Result') -FillWeight 14)
    [void](Add-SelectorTextColumn -Grid $problemGrid -Name 'Reason' -HeaderText (Get-SelectorText -Key 'Gui.Column.Reason') -FillWeight 32)
    foreach ($problem in $problems) {
        $index = $problemGrid.Rows.Add(@(
                (Get-W360StringProperty -Object $problem -Name 'Target'),
                (Get-W360StringProperty -Object $problem -Name 'ActionText'),
                (Get-W360StringProperty -Object $problem -Name 'ResultText'),
                (Get-W360StringProperty -Object $problem -Name 'ReasonText')))
        $raw = Get-W360StringProperty -Object $problem -Name 'RawDetail'
        if (-not [string]::IsNullOrWhiteSpace($raw)) { $problemGrid.Rows[$index].Cells[3].ToolTipText = $raw }
    }
    $problemTable = New-SelectorTable -Columns 1
    $problemTable.Dock = [Windows.Forms.DockStyle]::Fill
    [void]$problemTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    if ($problems.Count -eq 0) {
        [void](Add-SelectorTableRow -Table $problemTable -Control (New-SelectorLabel -Text (Get-SelectorText -Key 'Gui.Remove.NoProblems') -Color 'MutedText' -Name 'ProblemsNone'))
    }
    [void](Add-SelectorTableRow -Table $problemTable -Control $problemGrid -SizeType Percent -Height 100)
    $problemPage.Controls.Add($problemTable)

    $logPage = New-Object Windows.Forms.TabPage
    $logPage.Text = Get-SelectorText -Key 'Gui.Remove.LogTitle'
    $logPage.Name = 'LogTab'
    $logPage.Padding = New-Object Windows.Forms.Padding(4)
    $actionGrid = New-SelectorGrid -Name 'ActionGrid'
    [void](Add-SelectorTextColumn -Grid $actionGrid -Name 'Time' -HeaderText (Get-SelectorText -Key 'Gui.Column.Time') -FillWeight 14)
    [void](Add-SelectorTextColumn -Grid $actionGrid -Name 'Action' -HeaderText (Get-SelectorText -Key 'Gui.Column.Action') -FillWeight 18)
    [void](Add-SelectorTextColumn -Grid $actionGrid -Name 'Target' -HeaderText (Get-SelectorText -Key 'Gui.Column.Target') -FillWeight 30)
    [void](Add-SelectorTextColumn -Grid $actionGrid -Name 'Result' -HeaderText (Get-SelectorText -Key 'Gui.Column.Result') -FillWeight 12)
    [void](Add-SelectorTextColumn -Grid $actionGrid -Name 'Detail' -HeaderText (Get-SelectorText -Key 'Gui.Column.RawDetail') -FillWeight 30)
    foreach ($action in @(Get-W360ArrayProperty -Object (Get-W360PropertyValue -Object $Outcome -Name 'Report') -Name 'Actions')) {
        $actionName = Get-W360StringProperty -Object $action -Name 'Action'
        $result = Get-W360StringProperty -Object $action -Name 'Result'
        $index = $actionGrid.Rows.Add(@(
                (Get-W360StringProperty -Object $action -Name 'Time'),
                ((Get-W360ActionText -Action $actionName) + ' (' + $actionName + ')'),
                (Get-W360StringProperty -Object $action -Name 'Target'),
                ((Get-W360ActionResultText -Result $result) + ' (' + $result + ')'),
                (Get-W360StringProperty -Object $action -Name 'Detail')))
        $actionGrid.Rows[$index].Cells[4].ToolTipText = Get-W360StringProperty -Object $action -Name 'Detail'
    }
    $logTable = New-SelectorTable -Columns 1
    $logTable.Dock = [Windows.Forms.DockStyle]::Fill
    [void]$logTable.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void](Add-SelectorTableRow -Table $logTable -Control (New-SelectorLabel -Text (Get-SelectorText -Key 'Gui.Remove.LogIntro') -Color 'MutedText' -Name 'LogIntro'))
    [void](Add-SelectorTableRow -Table $logTable -Control $actionGrid -SizeType Percent -Height 100)
    $logPage.Controls.Add($logTable)

    [void]$tabs.TabPages.Add($statsPage)
    [void]$tabs.TabPages.Add($problemPage)
    [void]$tabs.TabPages.Add($logPage)
    # Someone who opens the details of "some were not deleted" wants to see what was not deleted first.
    if ($problems.Count -gt 0) { $tabs.SelectedIndex = 1 }
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $tabs -SizeType Percent -Height 100)
    $dialog.Data['Tabs'] = $tabs
    $dialog.Data['StatsText'] = $statsBox
    $dialog.Data['ProblemGrid'] = $problemGrid
    $dialog.Data['ActionGrid'] = $actionGrid
    $dialog.Grid = $problemGrid
    $dialog.DetailBox = $statsBox

    $open = Add-SelectorPageButton -Page $dialog -Name 'OpenReportFolder' -Text (Get-SelectorText -Key 'Ui.Button.OpenReportFolder') -OnClick {
        param($sender, $clickInfo)
        Invoke-SelectorUiAction -SelectorAction { Open-SelectorReportFolder -Path ([string]$sender.FindForm().Tag.ReportPath) }
    }
    $open.Enabled = -not [string]::IsNullOrWhiteSpace($dialog.ReportPath)
    $close = Add-SelectorPageButton -Page $dialog -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -Style Primary
    $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Data['Form'].AcceptButton = $close
    $dialog.Data['Form'].CancelButton = $close
    $dialog.InitialFocus = $close
    return (Complete-SelectorPage -Page $dialog)
}

function Show-SelectorRemoveDetails {
    param([Parameter(Mandatory = $true)][object]$Page)

    if ($null -eq (Get-W360PropertyValue -Object $Page.Outcome -Name 'Report')) { return }
    [void](Show-SelectorDialog -Dialog (New-SelectorRemoveDetailsDialog -Outcome $Page.Outcome))
}

function Get-SelectorVerifySectionColor {
    param([AllowEmptyString()][string]$Key)

    switch -CaseSensitive ($Key) {
        'SelectedRemaining' { return 'Error' }
        'Unknown' { return 'Warning' }
        'NewOrChanged' { return 'Warning' }
        'PreservedGone' { return 'Warning' }
        'CurrentKept' { return 'ReviewText' }
        'Cleared' { return 'Success' }
    }
    return 'Text'
}

function New-SelectorVerifyResultPage {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    $state = Get-SelectorOutcomeString -Outcome $Outcome -Name 'State'
    $page = New-SelectorPageObject -Kind 'VerifyResult'
    $page.Stage = 'Verify'
    $page.Outcome = $Outcome
    $page.ReportPath = Get-SelectorOutcomeString -Outcome $Outcome -Name 'ReportPath'
    Add-SelectorPageHeadline -Page $page -Headline (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Headline') `
        -Detail (Get-SelectorOutcomeString -Outcome $Outcome -Name 'Detail') -Color (Get-SelectorOutcomeColor -Outcome $Outcome) -FontSize 13

    $grid = New-SelectorGrid -Name 'VerifyGrid'
    [void](Add-SelectorTextColumn -Grid $grid -Name 'Item' -HeaderText (Get-SelectorText -Key 'Ui.Column.Item') -FillWeight 55 -MinimumWidth 120 -Wrap)
    [void](Add-SelectorTextColumn -Grid $grid -Name 'Result' -HeaderText (Get-SelectorText -Key 'Ui.Column.Result') -FillWeight 45 -MinimumWidth 100 -Wrap)
    Set-SelectorGridMinimumRows -Grid $grid -Rows 3

    # Only sections that have items are shown, in the library's order (what went wrong first, deleted last).
    $groupFont = Get-SelectorFont -Bold
    $indent = [int][Math]::Round(22 * $script:SelectorFontScale)
    $headerRows = New-Object System.Collections.Generic.List[int]
    foreach ($section in @(Get-W360ArrayProperty -Object $Outcome -Name 'GridSections')) {
        $key = Get-W360StringProperty -Object $section -Name 'Key'
        $title = Get-W360StringProperty -Object $section -Name 'Title'
        $items = @(Get-W360ArrayProperty -Object $section -Name 'Items')
        if ($items.Count -eq 0) { continue }
        $headerIndex = $grid.Rows.Add()
        $headerRow = $grid.Rows[$headerIndex]
        $headerRow.Tag = [pscustomobject]@{ Type = 'Group'; Key = $key; Title = $title; Count = $items.Count }
        $headerRow.Cells[0].Value = Get-SelectorText -Key 'Gui.Verify.SectionHeader' -Arguments @($title, $items.Count)
        $headerRow.Cells[0].ToolTipText = [string]$headerRow.Cells[0].Value
        $headerRow.DefaultCellStyle.BackColor = Get-SelectorColor -Name 'GroupBack'
        $headerRow.DefaultCellStyle.SelectionBackColor = Get-SelectorColor -Name 'GroupSelectedBack'
        $headerRow.DefaultCellStyle.ForeColor = Get-SelectorColor -Name 'Text'
        $headerRow.DefaultCellStyle.SelectionForeColor = Get-SelectorColor -Name 'Text'
        $headerRow.DefaultCellStyle.Font = $groupFont
        $headerRows.Add($headerIndex)
        $resultColor = Get-SelectorColor -Name (Get-SelectorVerifySectionColor -Key $key)
        foreach ($item in $items) {
            $index = $grid.Rows.Add()
            $row = $grid.Rows[$index]
            $row.Tag = [pscustomobject]@{ Type = 'Item'; Key = $key; Item = $item }
            $row.Cells[0].Value = Get-W360StringProperty -Object $item -Name 'DisplayName'
            $row.Cells[0].Style.Padding = New-Object Windows.Forms.Padding($indent, 0, 0, 0)
            $row.Cells[1].Value = Get-W360StringProperty -Object $item -Name 'StateText'
            $row.Cells[1].Style.ForeColor = $resultColor
            $row.Cells[1].Style.SelectionForeColor = $resultColor
        }
    }
    $grid.Tag = $page
    $page.Grid = $grid
    $page.Data['SectionHeaderRows'] = $headerRows
    $grid.Add_CellPainting({
            param($sender, $paintInfo)
            Invoke-SelectorGridCellPainting -Grid $sender -PaintInfo $paintInfo
        })
    $grid.Add_RowPostPaint({
            param($sender, $paintInfo)
            Invoke-SelectorGridRowPostPaint -Grid $sender -PaintInfo $paintInfo -FirstTextColumn 0
        })
    $grid.Add_CellMouseClick({
            param($sender, $clickInfo)
            Invoke-SelectorUiAction -SelectorAction {
                if ($clickInfo.RowIndex -ge 0) { Update-SelectorVerifyDetail -Page $sender.Tag -RowIndex $clickInfo.RowIndex }
            }
        })
    $grid.Add_CurrentCellChanged({
            param($sender, $changeInfo)
            try {
                if ($sender.ContainsFocus -and $null -ne $sender.CurrentRow) { Update-SelectorVerifyDetail -Page $sender.Tag -RowIndex $sender.CurrentRow.Index }
            }
            catch {}
        })
    [void](Add-SelectorTableRow -Table $page.Root -Control $grid -SizeType Percent -Height 100)
    [void](Add-SelectorDetailArea -Page $page -BoxName 'VerifyDetail' -Placeholder (Get-SelectorText -Key 'Gui.Verify.DetailPlaceholder'))

    $page.Data['NextStepsLabel'] = $null
    $nextText = Get-SelectorNextStepsText -Steps @(Get-W360ArrayProperty -Object $Outcome -Name 'NextSteps')
    if (-not [string]::IsNullOrWhiteSpace($nextText)) {
        $nextLabel = New-SelectorLabel -Text $nextText -Bold -Color 'Info' -Name 'NextSteps'
        [void](Add-SelectorTableRow -Table $page.Root -Control $nextLabel)
        $page.Data['NextStepsLabel'] = $nextLabel
    }

    # "Close" leads only when nothing more can be done now; otherwise checking the PC again leads.
    $closePrimary = ($state -ceq 'GlobalClean') -or ($state -ceq 'GlobalKeptOnly') -or
        ($state -ceq 'TaskCompleted' -and (Get-W360PropertyValue -Object $Outcome -Name 'CoverageComplete') -ne $false -and
            (ConvertTo-W360Int64 (Get-W360PropertyValue -Object $Outcome -Name 'PreservedChangedCount')) -eq 0 -and
            (ConvertTo-W360Int64 (Get-W360PropertyValue -Object $Outcome -Name 'PreservedUnknownCount')) -eq 0)
    $closeHandler = { Invoke-SelectorUiAction -SelectorAction { Close-SelectorApp } }
    $rescanHandler = { Invoke-SelectorUiAction -SelectorAction { Start-SelectorScan } }
    if ($closePrimary) {
        [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -Style Primary -OnClick $closeHandler)
        [void](Add-SelectorPageButton -Page $page -Name 'Rescan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -OnClick $rescanHandler)
    }
    else {
        [void](Add-SelectorPageButton -Page $page -Name 'Rescan' -Text (Get-SelectorText -Key 'Ui.Button.Rescan') -Style Primary -OnClick $rescanHandler)
        [void](Add-SelectorPageButton -Page $page -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close') -OnClick $closeHandler)
    }
    [void](Add-SelectorPageButton -Page $page -Name 'HelpSummary' -Text (Get-SelectorText -Key 'Ui.Button.HelpSummary') -OnClick {
            Invoke-SelectorUiAction -SelectorAction { Show-SelectorHelpSummaryForPage -Page $script:SelectorApp.Shell.CurrentPage }
        })
    $page.InitialFocus = $page.PrimaryButton
    return (Complete-SelectorPage -Page $page)
}

# The plain, localised explanation of a verify item, or '' when only the raw English detail exists
# (the raw detail is shown in the More info window).
function Get-SelectorVerifyPlainDetail {
    param([AllowNull()][object]$Item)

    if ((Get-W360StringProperty -Object $Item -Name 'Category') -ceq 'Coverage') { return (Get-SelectorText -Key 'Gui.Verify.CoverageHint') }
    if ((Get-W360StringProperty -Object $Item -Name 'Category') -ceq 'CurrentKept') { return (Get-W360StringProperty -Object $Item -Name 'Detail') }
    $code = Get-W360StringProperty -Object $Item -Name 'DetailCode'
    if ($code -match '^[A-Za-z]+$' -and (Test-W360TextKey -Key ('DetailCode.' + $code))) {
        return (Get-W360StringProperty -Object $Item -Name 'Detail')
    }
    return ''
}

function Update-SelectorVerifyDetail {
    param(
        [Parameter(Mandatory = $true)][object]$Page,
        [int]$RowIndex
    )

    if ($RowIndex -lt 0 -or $RowIndex -ge $Page.Grid.Rows.Count) { return }
    $info = $Page.Grid.Rows[$RowIndex].Tag
    if ($null -eq $info) { return }
    if ([string]$info.Type -ne 'Item') {
        Set-SelectorBoxText -Box $Page.DetailBox -Text ([string]$Page.Grid.Rows[$RowIndex].Cells[0].Value)
        Set-SelectorInfoRow -Page $Page -RowIndex -1
        return
    }
    $item = $info.Item
    $lines = @((Get-SelectorText -Key 'Gui.Verify.ItemLine' -Arguments @(
                (Get-W360StringProperty -Object $item -Name 'DisplayName'), (Get-W360StringProperty -Object $item -Name 'StateText'))))
    $plain = Get-SelectorVerifyPlainDetail -Item $item
    if (-not [string]::IsNullOrWhiteSpace($plain)) { $lines += $plain }
    Set-SelectorBoxText -Box $Page.DetailBox -Text (Join-SelectorLines -Lines $lines)
    Set-SelectorInfoRow -Page $Page -RowIndex $RowIndex
}

# Full technical description of one verify item for the More info window.
function Get-SelectorVerifyInfoText {
    param([Parameter(Mandatory = $true)][object]$Item)

    return (Join-SelectorLines -Lines @(
            (Get-W360StringProperty -Object $Item -Name 'DisplayName'),
            '',
            (Get-SelectorTextTitle -Key 'Gui.Detail.State'), (Get-W360StringProperty -Object $Item -Name 'StateText'),
            '',
            (Get-SelectorTextTitle -Key 'Gui.Detail.Explanation'), (Get-W360StringProperty -Object $Item -Name 'Detail'),
            '',
            (Get-SelectorTextTitle -Key 'Ui.Detail.Product'), (Get-W360StringProperty -Object $Item -Name 'ProductName'),
            '',
            (Get-SelectorTextTitle -Key 'Gui.Detail.Kind'), (Get-W360StringProperty -Object $Item -Name 'KindText'),
            '',
            (Get-SelectorTextTitle -Key 'Gui.Detail.Location'), (Get-W360StringProperty -Object $Item -Name 'Target'),
            '',
            (Get-SelectorTextTitle -Key 'Gui.Detail.RawDetail'), (Get-W360StringProperty -Object $Item -Name 'RawDetail')
        ))
}

# The More info text of the row remembered in Page.Data['InfoRowIndex'], or '' when no item row is current.
function Get-SelectorItemInfoText {
    param([Parameter(Mandatory = $true)][object]$Page)

    if ($null -eq $Page.Grid -or -not $Page.Data.ContainsKey('InfoRowIndex')) { return '' }
    $rowIndex = [int]$Page.Data['InfoRowIndex']
    if ($rowIndex -lt 0 -or $rowIndex -ge $Page.Grid.Rows.Count) { return '' }
    $info = $Page.Grid.Rows[$rowIndex].Tag
    if ($null -eq $info) { return '' }
    switch -CaseSensitive ([string]$info.Type) {
        'Finding' { return (Get-SelectorFindingInfoText -Finding $info.Finding -Effective $Page.Data['Effective']) }
        'Item' { return (Get-SelectorVerifyInfoText -Item $info.Item) }
    }
    return ''
}

# The More info window (technical words allowed) for the current item row; $null when no item row is current.
function New-SelectorItemInfoDialog {
    param([Parameter(Mandatory = $true)][object]$Page)

    $body = Get-SelectorItemInfoText -Page $Page
    if ([string]::IsNullOrWhiteSpace($body)) { return $null }
    $dialog = New-SelectorTextDialog -Title (Get-SelectorText -Key 'Ui.Button.MoreInfo') -Body $body
    $dialog.Kind = 'ItemInfoDialog'
    return $dialog
}

function Show-SelectorItemInfo {
    param([Parameter(Mandatory = $true)][object]$Page)

    $dialog = New-SelectorItemInfoDialog -Page $Page
    if ($null -ne $dialog) { [void](Show-SelectorDialog -Dialog $dialog) }
}

# The technical reason of an error page, one click away from the page.
function New-SelectorTechnicalTextDialog {
    param([AllowNull()][AllowEmptyString()][string]$ErrorText = '')

    $body = if ([string]::IsNullOrWhiteSpace($ErrorText)) { Get-SelectorText -Key 'Gui.Error.NoTechnical' } else { [string]$ErrorText }
    $dialog = New-SelectorTextDialog -Title (Get-SelectorText -Key 'Gui.Error.TechnicalTitle') -Body $body
    $dialog.Kind = 'TechnicalTextDialog'
    return $dialog
}

function Show-SelectorTechnicalText {
    param([Parameter(Mandatory = $true)][object]$Page)
    [void](Show-SelectorDialog -Dialog (New-SelectorTechnicalTextDialog -ErrorText ([string]$Page.ErrorText)))
}

function New-SelectorHelpSummaryDialog {
    param(
        [AllowEmptyString()][string]$Text = '',
        [AllowEmptyString()][string]$SaveDirectory = '',
        # The record (report) file of the current page; "Open the records folder" selects it in Explorer.
        [AllowNull()][AllowEmptyString()][string]$ReportPath = ''
    )

    $dialog = New-SelectorDialogShell -Title (Get-SelectorText -Key 'Ui.Help.Title') -Width 780 -Height 620
    $dialog.Kind = 'HelpDialog'
    $dialog.Data['SaveDirectory'] = $SaveDirectory
    $dialog.ReportPath = [string]$ReportPath
    Add-SelectorPageHeadline -Page $dialog -Headline (Get-SelectorText -Key 'Ui.Help.Title') `
        -Detail (Get-SelectorText -Key 'Ui.Help.Privacy') -Color 'Text'
    $dialog.DetailLabel.Font = Get-SelectorFont -Bold
    $dialog.DetailLabel.ForeColor = Get-SelectorColor -Name 'Warning'
    $box = New-SelectorReadOnlyTextBox -Text $Text -Editable
    $box.Name = 'HelpText'
    $box.AccessibleName = Get-SelectorText -Key 'Ui.Help.Title'
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $box -SizeType Percent -Height 100)
    $dialog.DetailBox = $box
    $status = New-SelectorLabel -Text '' -Color 'Info' -Name 'HelpStatus'
    [void](Add-SelectorTableRow -Table $dialog.Root -Control $status)
    $dialog.Data['StatusLabel'] = $status

    [void](Add-SelectorPageButton -Page $dialog -Name 'Copy' -Text (Get-SelectorText -Key 'Ui.Button.Copy') -Style Primary -OnClick {
            param($sender, $clickInfo)
            Invoke-SelectorHelpDialogAction -Dialog $sender.FindForm().Tag -Action 'Copy'
        })
    [void](Add-SelectorPageButton -Page $dialog -Name 'SaveText' -Text (Get-SelectorText -Key 'Ui.Button.SaveText') -OnClick {
            param($sender, $clickInfo)
            Invoke-SelectorHelpDialogAction -Dialog $sender.FindForm().Tag -Action 'Save'
        })
    [void](Add-SelectorPageButton -Page $dialog -Name 'OpenGitHub' -Text (Get-SelectorText -Key 'Ui.Button.OpenGitHub') -OnClick {
            param($sender, $clickInfo)
            Invoke-SelectorHelpDialogAction -Dialog $sender.FindForm().Tag -Action 'Browser'
        })
    $open = Add-SelectorPageButton -Page $dialog -Name 'OpenReportFolder' -Text (Get-SelectorText -Key 'Ui.Button.OpenReportFolder') -OnClick {
        param($sender, $clickInfo)
        Invoke-SelectorHelpDialogAction -Dialog $sender.FindForm().Tag -Action 'OpenFolder'
    }
    $open.Enabled = -not [string]::IsNullOrWhiteSpace($dialog.ReportPath)
    $close = Add-SelectorPageButton -Page $dialog -Name 'Close' -Text (Get-SelectorText -Key 'Ui.Button.Close')
    $close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dialog.Data['Form'].CancelButton = $close
    return (Complete-SelectorPage -Page $dialog)
}

# The address "Open the help web page" opens: always the fixed issue form, whatever the preview says.
function Get-SelectorHelpBrowserTarget {
    param([AllowNull()][object]$Dialog)
    return [string]$script:SelectorHelpIssueUrl
}

function Open-SelectorHelpBrowser {
    param([Parameter(Mandatory = $true)][string]$Target)

    $startInfo = New-Object Diagnostics.ProcessStartInfo($Target)
    $startInfo.UseShellExecute = $true
    [void][Diagnostics.Process]::Start($startInfo)
}

function Invoke-SelectorHelpDialogAction {
    param(
        [AllowNull()][object]$Dialog,
        [ValidateSet('Copy', 'Save', 'Browser', 'OpenFolder')][string]$Action
    )

    if ($null -eq $Dialog) { return }
    $status = $Dialog.Data['StatusLabel']
    try {
        switch ($Action) {
            'Copy' {
                $text = [string]$Dialog.DetailBox.Text
                if ([string]::IsNullOrEmpty($text)) { return }
                [Windows.Forms.Clipboard]::SetText($text)
                $status.Text = Get-SelectorText -Key 'Gui.Help.CopyDone'
            }
            'Save' {
                try {
                    $path = Save-W360HelpSummary -Directory ([string]$Dialog.Data['SaveDirectory']) -Text ([string]$Dialog.DetailBox.Text)
                    $status.Text = Get-SelectorText -Key 'Ui.Help.Saved' -Arguments @($path)
                }
                catch { $status.Text = Get-SelectorText -Key 'Gui.Help.SaveFailed' -Arguments @($_.Exception.Message) }
            }
            'Browser' {
                try {
                    # Opens the fixed public issue form in the default browser. Nothing is sent by this tool: the
                    # summary is never part of the address.
                    Open-SelectorHelpBrowser -Target (Get-SelectorHelpBrowserTarget -Dialog $Dialog)
                }
                catch { $status.Text = Get-SelectorText -Key 'Gui.Help.BrowserFailed' -Arguments @($_.Exception.Message) }
            }
            'OpenFolder' {
                if ([string]::IsNullOrWhiteSpace([string]$Dialog.ReportPath)) { return }
                Open-SelectorReportFolder -Path ([string]$Dialog.ReportPath)
            }
        }
    }
    catch {
        try { $status.Text = Get-SelectorText -Key 'Gui.Help.CopyFailed' -Arguments @($_.Exception.Message) } catch {}
    }
}

function Get-SelectorPowerShellPath {
    try {
        $candidate = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    catch {}
    return 'powershell.exe'
}

function Get-SelectorScanArguments {
    param([Parameter(Mandatory = $true)][string]$ReportPath)
    return [string[]]@('-Mode', 'Scan', '-ReportPath', $ReportPath, '-EmitProgress')
}

function Get-SelectorVerifyArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [AllowNull()][AllowEmptyString()][string]$PreviousRemoveReport = ''
    )

    $arguments = @('-Mode', 'Verify', '-ReportPath', $ReportPath, '-EmitProgress')
    if (-not [string]::IsNullOrWhiteSpace($PreviousRemoveReport)) {
        $arguments += @('-PreviousRemoveReport', $PreviousRemoveReport)
    }
    return [string[]]$arguments
}

function Get-SelectorRemoveArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ScanReportPath,
        [Parameter(Mandatory = $true)][string]$ScanReportHash,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$SelectedIds,
        [Parameter(Mandatory = $true)][string]$RemoveReportPath,
        [Parameter(Mandatory = $true)][string]$ProgressFilePath
    )

    if ($ScanReportHash -notmatch '^[0-9A-Fa-f]{64}$') { throw 'The approved scan report hash is not a SHA-256 value.' }
    $ids = @($SelectedIds | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() })
    if ($ids.Count -lt 1 -or $ids.Count -gt 64) { throw 'A removal needs between 1 and 64 selected items.' }
    foreach ($id in $ids) {
        if ($id -notmatch '^[0-9A-F]{64}$') { throw 'A selected item has an invalid selection ID.' }
    }
    if (@($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'The selection contains duplicate IDs.' }
    return [string[]]@(
        '-Mode', 'Remove', '-ConfirmRemoval', '-ConfirmationPhrase', 'REMOVE-CONFIRMED-360',
        '-ApprovedReport', $ScanReportPath, '-ApprovedReportHash', $ScanReportHash.ToUpperInvariant(),
        '-SelectedFindingIds', ($ids -join ';'), '-ReportPath', $RemoveReportPath,
        '-EmitProgress', '-ElevatedProgressPath', $ProgressFilePath
    )
}

function Test-SelectorScanReportUnchanged {
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyString()][string]$ExpectedHash
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]$ExpectedHash -notmatch '^[0-9A-Fa-f]{64}$') { return $false }
    try { $current = Get-W360FileSha256 -Path $Path }
    catch { return $false }
    return $current.Equals([string]$ExpectedHash, [StringComparison]::OrdinalIgnoreCase)
}

function Get-SelectorCloseDecision {
    param(
        [AllowNull()][object]$Job,
        [AllowEmptyString()][string]$CloseReason = 'UserClosing'
    )

    if ($null -eq $Job) { return 'Allow' }
    if ([bool](Get-W360PropertyValue -Object $Job.State -Name 'Completed')) { return 'Allow' }
    if ($CloseReason -eq 'WindowsShutDown') { return 'Allow' }
    if ([string]$Job.Kind -eq 'Remove') { return 'BlockRemove' }
    return 'AskCancel'
}

function Show-SelectorMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('Information', 'Warning', 'Error', 'Question')][string]$Icon = 'Information',
        [ValidateSet('OK', 'YesNo')][string]$Buttons = 'OK',
        [switch]$SecondButtonDefault
    )

    $caption = 'Windows 360 Cleaner'
    try { $caption = Get-SelectorText -Key 'App.WindowTitle' -Arguments @($script:W360ToolVersion) } catch {}
    $owner = $null
    if ($null -ne $script:SelectorApp -and -not $script:SelectorApp.Form.IsDisposed) { $owner = $script:SelectorApp.Form }
    $defaultButton = if ($SecondButtonDefault) { [Windows.Forms.MessageBoxDefaultButton]::Button2 } else { [Windows.Forms.MessageBoxDefaultButton]::Button1 }
    if ($null -ne $owner) {
        return [Windows.Forms.MessageBox]::Show($owner, $Text, $caption, [Windows.Forms.MessageBoxButtons]::$Buttons,
            [Windows.Forms.MessageBoxIcon]::$Icon, $defaultButton)
    }
    return [Windows.Forms.MessageBox]::Show($Text, $caption, [Windows.Forms.MessageBoxButtons]::$Buttons,
        [Windows.Forms.MessageBoxIcon]::$Icon, $defaultButton)
}

function New-SelectorApp {
    param(
        [Parameter(Mandatory = $true)][string]$ReportDirectory,
        [Parameter(Mandatory = $true)][string]$CoreScriptPath,
        [string]$PowerShellPath = (Get-SelectorPowerShellPath)
    )

    $shell = New-SelectorMainForm
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ Invoke-SelectorTimerTick })
    return [pscustomobject]@{
        Shell           = $shell
        Form            = $shell.Form
        Timer           = $timer
        ReportDirectory = $ReportDirectory
        CoreScriptPath  = $CoreScriptPath
        PowerShellPath  = $PowerShellPath
        Job             = $null
        TimerBusy       = $false
        Starting        = $false
    }
}

function Show-SelectorPage {
    param([Parameter(Mandatory = $true)][object]$Page)

    $app = $script:SelectorApp
    if ($null -eq $app -or $app.Form.IsDisposed) {
        try { $Page.Root.Dispose() } catch {}
        return
    }
    Set-SelectorPage -Shell $app.Shell -Page $Page
}

function Invoke-SelectorUiAction {
    param([Parameter(Mandatory = $true)][scriptblock]$SelectorAction)

    try { & $SelectorAction }
    catch { Show-SelectorUnexpectedError -ErrorRecord $_ }
}

function Get-SelectorErrorRecordText {
    param([AllowNull()][object]$ErrorRecord)

    if ($null -eq $ErrorRecord) { return '' }
    $parts = New-Object System.Collections.Generic.List[string]
    try { $parts.Add([string]$ErrorRecord.Exception.Message) } catch { $parts.Add([string]$ErrorRecord) }
    try {
        $stack = [string]$ErrorRecord.ScriptStackTrace
        if (-not [string]::IsNullOrWhiteSpace($stack)) { $parts.Add($stack) }
    }
    catch {}
    return ($parts.ToArray() -join "`r`n")
}

function Show-SelectorUnexpectedError {
    param([AllowNull()][object]$ErrorRecord)

    $errorText = Get-SelectorErrorRecordText -ErrorRecord $ErrorRecord
    try {
        $app = $script:SelectorApp
        if ($null -ne $app -and $null -ne $app.Job) {
            if ([string]$app.Job.Kind -eq 'Remove' -and -not [bool]$app.Job.State.Completed) {
                # A running deletion is never abandoned: keep its progress page and keep polling. The message says
                # the deletion is still running so nobody closes the window or powers off.
                [void](Show-SelectorMessage -Text ((Get-SelectorText -Key 'Gui.Error.UnexpectedDuringRemove') + "`r`n`r`n" + $errorText) -Icon Warning)
                return
            }
            if ([string]$app.Job.Kind -ne 'Remove') {
                try { Stop-W360ChildProcess -State $app.Job.State } catch {}
            }
            $app.Timer.Stop()
            $app.Job = $null
        }
        Show-SelectorPage -Page (New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.Unexpected.Headline') `
                -Detail (Get-SelectorText -Key 'Gui.Error.Unexpected.Detail') -ErrorText $errorText -Stage Error)
    }
    catch {
        try { [void](Show-SelectorMessage -Text ($errorText + "`r`n`r`n" + $_.Exception.Message) -Icon Error) }
        catch { try { [Console]::Error.WriteLine($errorText) } catch {} }
    }
}

function Close-SelectorApp {
    $app = $script:SelectorApp
    if ($null -ne $app -and -not $app.Form.IsDisposed) { $app.Form.Close() }
}

function Invoke-SelectorFormClosing {
    param([Parameter(Mandatory = $true)][object]$ClosingInfo)

    try {
        $app = $script:SelectorApp
        if ($null -eq $app) { return }
        $decision = Get-SelectorCloseDecision -Job $app.Job -CloseReason ([string]$ClosingInfo.CloseReason)
        switch ($decision) {
            'BlockRemove' {
                $ClosingInfo.Cancel = $true
                [void](Show-SelectorMessage -Text (Get-SelectorText -Key 'Ui.Close.BlockedDuringRemove') -Icon Warning)
            }
            'AskCancel' {
                # "No" stays the default answer: Enter keeps the check running.
                $answer = Show-SelectorMessage -Text (Get-SelectorText -Key 'Ui.Close.CancelFirst') -Icon Question -Buttons YesNo -SecondButtonDefault
                if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
                    $ClosingInfo.Cancel = $true
                    return
                }
                if ($null -ne $app.Job -and [string]$app.Job.Kind -ne 'Remove') {
                    try { Stop-W360ChildProcess -State $app.Job.State } catch {}
                }
                $app.Timer.Stop()
                $app.Job = $null
            }
            default { $app.Timer.Stop() }
        }
    }
    catch {
        # Never let a failure here close the window during a deletion.
        try {
            if ($null -ne $script:SelectorApp -and $null -ne $script:SelectorApp.Job -and
                [string]$script:SelectorApp.Job.Kind -eq 'Remove' -and -not [bool]$script:SelectorApp.Job.State.Completed) {
                $ClosingInfo.Cancel = $true
            }
        }
        catch {}
    }
}

function Start-SelectorChildJob {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan', 'Verify', 'Remove')][string]$Kind,
        [Parameter(Mandatory = $true)][string[]]$CoreArguments,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [AllowEmptyString()][string]$ProgressFilePath = '',
        [AllowNull()][object]$Context = $null,
        # A verify without a previous deletion record checks the whole PC.
        [switch]$Global
    )

    $app = $script:SelectorApp
    if ($null -ne $app.Job) { return $false }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $app.CoreScriptPath) + @($CoreArguments)
    # Build everything that can fail before the child starts, so a failure here always means "not started".
    $page = New-SelectorProgressPage -Kind $Kind -Global:$Global
    $state = Start-W360ChildProcess -FilePath $app.PowerShellPath -ArgumentList $arguments
    # From here on the child is running: attach it at once and keep polling even if showing the page fails.
    $app.Job = [pscustomobject]@{
        Kind             = $Kind
        State            = $state
        ReportPath       = $ReportPath
        ProgressFilePath = $ProgressFilePath
        Page             = $page
        Context          = $Context
        PollFailures     = 0
        LastPollError    = ''
    }
    try { $app.Timer.Start() }
    finally { Show-SelectorPage -Page $page }
    return $true
}

function Start-SelectorScan {
    $app = $script:SelectorApp
    if ($null -ne $app.Job) { return }
    try {
        $reportPath = New-W360ReportPath -Directory $app.ReportDirectory -Kind 'scan'
        [void](Start-SelectorChildJob -Kind Scan -CoreArguments (Get-SelectorScanArguments -ReportPath $reportPath) -ReportPath $reportPath)
    }
    catch {
        if ($null -ne $app.Job) {
            # The read-only child already started; stop it and show the unexpected-error page.
            Show-SelectorUnexpectedError -ErrorRecord $_
            return
        }
        Show-SelectorPage -Page (New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.StartFailed.Headline') `
                -Detail (Get-SelectorText -Key 'Gui.Error.StartFailed.Detail') `
                -ErrorText (Get-SelectorErrorRecordText -ErrorRecord $_) -Stage Scan)
    }
}

function Start-SelectorVerify {
    param([AllowNull()][AllowEmptyString()][string]$PreviousRemoveReport = '')

    $app = $script:SelectorApp
    if ($null -ne $app.Job) { return }
    try {
        $reportPath = New-W360ReportPath -Directory $app.ReportDirectory -Kind 'verify'
        $arguments = Get-SelectorVerifyArguments -ReportPath $reportPath -PreviousRemoveReport $PreviousRemoveReport
        $wholePc = [string]::IsNullOrWhiteSpace($PreviousRemoveReport)
        [void](Start-SelectorChildJob -Kind Verify -CoreArguments $arguments -ReportPath $reportPath -Global:$wholePc)
    }
    catch {
        if ($null -ne $app.Job) {
            Show-SelectorUnexpectedError -ErrorRecord $_
            return
        }
        Show-SelectorPage -Page (New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.StartFailed.Headline') `
                -Detail (Get-SelectorText -Key 'Gui.Error.StartFailed.Detail') `
                -ErrorText (Get-SelectorErrorRecordText -ErrorRecord $_) -Stage Verify)
    }
}

function Get-SelectorTaskRemoveReportPath {
    param([AllowNull()][object]$TaskState)

    $record = Get-W360PropertyValue -Object (Get-W360PropertyValue -Object $TaskState -Name 'TaskInfo') -Name 'Record'
    return (Get-W360StringProperty -Object $record -Name 'RemoveReportPath')
}

function Start-SelectorTaskVerify {
    param([AllowNull()][object]$TaskState)
    Start-SelectorVerify -PreviousRemoveReport (Get-SelectorTaskRemoveReportPath -TaskState $TaskState)
}

function Start-SelectorVerifyAfterRemove {
    param([Parameter(Mandatory = $true)][object]$Page)

    $path = [string]$Page.ReportPath
    $previous = ''
    try { if (-not [string]::IsNullOrWhiteSpace($path) -and [IO.File]::Exists($path)) { $previous = $path } } catch {}
    Start-SelectorVerify -PreviousRemoveReport $previous
}

function Get-SelectorValidTaskState {
    $app = $script:SelectorApp
    $found = Find-W360LatestVerifiableTask -Directory $app.ReportDirectory -LastBootTime (Get-W360LastBootTime)
    if ($null -eq $found) { return $null }
    $state = $found.TaskState
    $state | Add-Member -NotePropertyName NewerUnusableCount -NotePropertyValue ([int]$found.NewerUnusableCount) -Force
    return $state
}

function Invoke-SelectorCleanRequest {
    param([Parameter(Mandatory = $true)][object]$Page)

    $app = $script:SelectorApp
    if ($null -ne $app.Job -or [string]$Page.Kind -ne 'ScanResult' -or -not $Page.Buttons.Contains('CleanSelected')) { return }
    $cleanButton = $Page.Buttons['CleanSelected']
    $cleanButton.Enabled = $false
    try {
        $findings = @(Get-W360ArrayProperty -Object $Page.Outcome -Name 'Findings')
        $ids = Get-SelectorSelectedIds -Page $Page
        $plan = $null
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            $plan = Get-W360SelectionPlan -Findings $findings -SelectedIds $ids
            if ([bool]$plan.CanSubmit) { break }
            $result = Show-SelectorDialog -Dialog (New-SelectorPlanProblemDialog -Plan $plan -DeletableIds ([string[]]@($Page.Data['SelectableById'].Keys)))
            if ($result -ne [Windows.Forms.DialogResult]::Yes) { return }
            # Only after the explicit click: add exactly the child/root items the plan named that can be ticked.
            Set-SelectorSelectedIds -Page $Page -Ids (Add-SelectorPlanChildren -Page $Page -Plan $plan -SelectedIds $ids)
            $ids = Get-SelectorSelectedIds -Page $Page
            $plan = $null
        }
        if ($null -eq $plan -or -not [bool]$plan.CanSubmit) { return }

        # "Cancel" is the default of the confirmation; only an explicit click on "Delete" returns OK.
        $answer = Show-SelectorDialog -Dialog (New-SelectorConfirmDialog -Plan $plan -AllFindings $findings -Effective $Page.Data['Effective'])
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
        Start-SelectorRemove -Plan $plan -ScanOutcome $Page.Outcome
    }
    finally {
        if (-not $cleanButton.IsDisposed) { $cleanButton.Enabled = ($Page.Data['Selection'].Count -ge 1) }
    }
}

function Start-SelectorRemove {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][object]$ScanOutcome
    )

    $app = $script:SelectorApp
    if ($null -ne $app.Job) { return }
    $scanPath = Get-W360StringProperty -Object $ScanOutcome -Name 'ReportPath'
    $scanHash = Get-W360StringProperty -Object $ScanOutcome -Name 'ReportHash'
    if (-not (Test-SelectorScanReportUnchanged -Path $scanPath -ExpectedHash $scanHash)) {
        Show-SelectorPage -Page (New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.ReportChanged.Headline') `
                -Detail (Get-SelectorText -Key 'Ui.Error.ReportChanged') -Stage Scan -Outcome $ScanOutcome -ReportPath $scanPath -NextSteps '')
        return
    }

    $selectedFindings = @(Get-W360ArrayProperty -Object $Plan -Name 'SelectedFindings')
    try {
        $removePath = New-W360ReportPath -Directory $app.ReportDirectory -Kind 'remove'
        $progressPath = New-W360ProgressFilePath
        $arguments = Get-SelectorRemoveArguments -ScanReportPath $scanPath -ScanReportHash $scanHash `
            -SelectedIds @(Get-W360ArrayProperty -Object $Plan -Name 'SelectedIds') -RemoveReportPath $removePath -ProgressFilePath $progressPath
        [void](New-W360TaskRecord -Directory $app.ReportDirectory -ScanReportPath $scanPath -ScanReportHash $scanHash `
                -RemoveReportPath $removePath -SelectedFindings $selectedFindings `
                -PreservedFindings @(Get-W360ArrayProperty -Object $Plan -Name 'PreservedFindings'))
    }
    catch {
        Show-SelectorPage -Page (New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Gui.Error.TaskRecordFailed.Headline') `
                -Detail (Get-SelectorText -Key 'Gui.Error.TaskRecordFailed.Detail') `
                -ErrorText (Get-SelectorErrorRecordText -ErrorRecord $_) -Stage Error)
        return
    }

    try {
        [void](Start-SelectorChildJob -Kind Remove -CoreArguments $arguments -ReportPath $removePath -ProgressFilePath $progressPath `
                -Context ([pscustomobject]@{ ScanReportHash = $scanHash; ScanReportPath = $scanPath; SelectedFindings = $selectedFindings }))
    }
    catch {
        $startError = $_
        if ($null -ne $app.Job -and [string]$app.Job.Kind -eq 'Remove') {
            # The deletion child is already running: never claim it did not start and keep its progress file.
            try { if (-not $app.Timer.Enabled) { $app.Timer.Start() } } catch {}
            Show-SelectorUnexpectedError -ErrorRecord $startError
            return
        }
        Remove-W360ProgressFile -Path $progressPath
        Show-SelectorPage -Page (New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Remove.NotStarted.Headline') `
                -Detail (Get-SelectorText -Key 'Gui.Error.RemoveStartFailed.Detail') `
                -ErrorText (Get-SelectorErrorRecordText -ErrorRecord $startError) -Stage Remove)
    }
}

function Stop-SelectorRunningJob {
    $app = $script:SelectorApp
    $job = $app.Job
    if ($null -eq $job -or [string]$job.Kind -eq 'Remove' -or [bool]$job.State.Completed) { return }
    $cancel = $job.Page.Data['CancelButton']
    if ($null -ne $cancel) {
        $cancel.Enabled = $false
        $cancel.Text = Get-SelectorText -Key 'Gui.Progress.Cancelling'
    }
    Stop-W360ChildProcess -State $job.State
}

function Invoke-SelectorTimerTick {
    $app = $script:SelectorApp
    if ($null -eq $app -or [bool]$app.TimerBusy) { return }
    $app.TimerBusy = $true
    try {
        $job = $app.Job
        if ($null -eq $job) {
            $app.Timer.Stop()
            return
        }
        $pollFailed = $false
        try {
            [void](Update-W360ChildProcess -State $job.State -ProgressFilePath ([string]$job.ProgressFilePath))
            $job.PollFailures = 0
        }
        catch {
            $job.PollFailures = [int]$job.PollFailures + 1
            $job.LastPollError = $_.Exception.Message
            $pollFailed = $true
        }
        try {
            Update-SelectorProgressPage -Page $job.Page -State $job.State
            if ($pollFailed) { $job.Page.Data['PhaseLabel'].Text = Get-SelectorText -Key 'Gui.Progress.PollProblem' }
        }
        catch {}

        if ([bool]$job.State.Completed) {
            Complete-SelectorJob -Job $job
        }
        elseif ($pollFailed -and [int]$job.PollFailures -ge 40) {
            $exited = $true
            try { $exited = [bool]$job.State.Process.HasExited } catch { $exited = $true }
            if ($exited) {
                $exitCode = $null
                try { $exitCode = [int]$job.State.Process.ExitCode } catch { $exitCode = $null }
                $job.State.ExitCode = $exitCode
                $job.State.Completed = $true
                [void]$job.State.StderrLines.Add(('Progress polling failed: ' + [string]$job.LastPollError))
                Complete-SelectorJob -Job $job
            }
        }
    }
    catch {
        Show-SelectorUnexpectedError -ErrorRecord $_
    }
    finally {
        $app.TimerBusy = $false
    }
}

function Complete-SelectorJob {
    param([Parameter(Mandatory = $true)][object]$Job)

    $app = $script:SelectorApp
    $state = $Job.State
    if (-not [bool]$state.Completed) { return }
    $app.Timer.Stop()
    $app.Job = $null
    $stdout = @(Get-W360ArrayProperty -Object $state -Name 'StdoutLines')
    $stderr = @(Get-W360ArrayProperty -Object $state -Name 'StderrLines')
    $cancelled = [bool](Get-W360PropertyValue -Object $state -Name 'Cancelled')

    switch ([string]$Job.Kind) {
        'Scan' {
            # Reading a large report and working out what can be deleted takes a moment on this thread: show the wait cursor.
            $page = Invoke-SelectorWithWaitCursor -Action {
                $outcome = Get-W360ScanOutcome -ExitCode $state.ExitCode -ReportPath $Job.ReportPath -Cancelled:$cancelled `
                    -StdoutLines $stdout -StderrLines $stderr
                New-SelectorPageForScanOutcome -Outcome $outcome
            }
            Show-SelectorPage -Page $page
        }
        'Verify' {
            $outcome = Get-W360VerifyOutcome -ExitCode $state.ExitCode -ReportPath $Job.ReportPath -Cancelled:$cancelled `
                -StdoutLines $stdout -StderrLines $stderr
            Show-SelectorPage -Page (New-SelectorPageForVerifyOutcome -Outcome $outcome)
        }
        'Remove' {
            try {
                $expected = Get-W360StringProperty -Object $Job.Context -Name 'ScanReportHash'
                # Older jobs (and test fixtures) may not carry the selected findings; problems then use target names.
                $selectedFindings = @(Get-W360ArrayProperty -Object $Job.Context -Name 'SelectedFindings')
                $outcome = Get-W360RemoveOutcome -ExitCode $state.ExitCode -ReportPath $Job.ReportPath `
                    -ExpectedApprovedReportHash $expected -Events @(Get-W360ArrayProperty -Object $state -Name 'Events') `
                    -StdoutLines $stdout -StderrLines $stderr -SelectedFindings $selectedFindings
                $page = New-SelectorRemoveResultPage -Outcome $outcome
            }
            catch {
                # The result could not be read: never claim success or "nothing deleted".
                $page = New-SelectorErrorPage -Headline (Get-SelectorText -Key 'Remove.Unknown.Headline') `
                    -Detail (Get-SelectorText -Key 'Gui.Error.RemoveCrashed.Detail' -Arguments @((Get-SelectorText -Key 'Ui.Button.VerifyTask'))) `
                    -ErrorText (Get-SelectorErrorRecordText -ErrorRecord $_) -Stage Remove -ReportPath $Job.ReportPath -Tone Warning -NextSteps ''
            }
            finally {
                Remove-W360ProgressFile -Path ([string]$Job.ProgressFilePath)
            }
            Show-SelectorPage -Page $page
        }
    }
}

function New-SelectorPageForScanOutcome {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    switch ([string]$Outcome.State) {
        'Findings' { return (New-SelectorScanResultPage -Outcome $Outcome) }
        'NoMatches' { return (New-SelectorNoMatchPage -Outcome $Outcome) }
        'NoMatchesIncomplete' { return (New-SelectorNoMatchPage -Outcome $Outcome) }
    }
    # A stopped check says it did not finish; failed and invalid details already say what to do next.
    $cancelled = [string]$Outcome.State -eq 'Cancelled'
    $tone = if ($cancelled) { 'Neutral' } else { 'Error' }
    $next = if ($cancelled) { Get-SelectorText -Key 'Gui.Error.CancelledNext' } else { '' }
    return (New-SelectorErrorPage -Headline ([string]$Outcome.Headline) -Detail ([string]$Outcome.Detail) `
            -ErrorText ([string]$Outcome.ErrorText) -Stage Scan -Outcome $Outcome -ReportPath ([string]$Outcome.ReportPath) -Tone $tone -NextSteps $next)
}

function New-SelectorPageForVerifyOutcome {
    param([Parameter(Mandatory = $true)][object]$Outcome)

    if (@('Cancelled', 'Failed', 'InvalidReport') -contains [string]$Outcome.State) {
        $tone = if ([string]$Outcome.State -eq 'Cancelled') { 'Neutral' } else { 'Error' }
        $next = (@(Get-W360ArrayProperty -Object $Outcome -Name 'NextSteps') | ForEach-Object { [string]$_ }) -join ' '
        return (New-SelectorErrorPage -Headline ([string]$Outcome.Headline) -Detail ([string]$Outcome.Detail) `
                -ErrorText ([string]$Outcome.ErrorText) -Stage Verify -Outcome $Outcome -ReportPath ([string]$Outcome.ReportPath) -Tone $tone -NextSteps $next)
    }
    return (New-SelectorVerifyResultPage -Outcome $Outcome)
}

function Show-SelectorCoverageDialog {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Issues)
    [void](Show-SelectorDialog -Dialog (New-SelectorCoverageDialog -Issues $Issues))
}

function Show-SelectorHelpSummaryForPage {
    param([Parameter(Mandatory = $true)][object]$Page)

    $app = $script:SelectorApp
    $previousCursor = $app.Form.Cursor
    $app.Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        $reportPath = [string]$Page.ReportPath
        if ([string]::IsNullOrWhiteSpace($reportPath)) { $reportPath = Get-W360StringProperty -Object $Page.Outcome -Name 'ReportPath' }
        $text = New-W360HelpSummary -Stage ([string]$Page.Stage) -Outcome $Page.Outcome -ErrorText ([string]$Page.ErrorText) `
            -ReportPath $reportPath -Context (New-W360RedactionContext)
    }
    finally { $app.Form.Cursor = $previousCursor }
    [void](Show-SelectorDialog -Dialog (New-SelectorHelpSummaryDialog -Text $text -SaveDirectory $app.ReportDirectory -ReportPath $reportPath))
}

function Open-SelectorReportFolder {
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]'"') -ge 0) { return }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $explorer = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)) 'explorer.exe'
        if (-not [IO.File]::Exists($explorer)) { $explorer = 'explorer.exe' }
        if ([IO.File]::Exists($full)) {
            $argumentText = '/select,"' + $full + '"'
        }
        else {
            $directory = [IO.Path]::GetDirectoryName($full)
            if ([string]::IsNullOrWhiteSpace($directory) -or -not [IO.Directory]::Exists($directory)) { return }
            if ($directory.Length -gt 3) { $directory = $directory.TrimEnd('\') }
            $argumentText = '"' + $directory + '"'
        }
        [void][Diagnostics.Process]::Start($explorer, $argumentText)
    }
    catch {
        [void](Show-SelectorMessage -Text (Get-SelectorText -Key 'Gui.OpenFolder.Failed' -Arguments @($_.Exception.Message)) -Icon Warning)
    }
}

function Invoke-SelectorStartup {
    param([ValidateSet('Auto', 'Scan', 'Verify')][string]$Mode = 'Auto')

    $app = $script:SelectorApp
    if ($null -eq $app -or [bool]$app.Starting) { return }
    $app.Starting = $true
    try {
        switch ($Mode) {
            'Scan' { Start-SelectorScan }
            'Verify' {
                Show-SelectorPage -Page (New-SelectorLoadingPage)
                $app.Form.Refresh()
                $taskState = $null
                try { $taskState = Get-SelectorValidTaskState } catch { $taskState = $null }
                if ($null -ne $taskState) { Start-SelectorTaskVerify -TaskState $taskState }
                else { Start-SelectorVerify -PreviousRemoveReport '' }
            }
            default {
                Show-SelectorPage -Page (New-SelectorLoadingPage)
                $app.Form.Refresh()
                # A damaged task record must never block the first read-only check.
                $taskState = $null
                try { $taskState = Get-SelectorValidTaskState } catch { $taskState = $null }
                if ($null -ne $taskState) { Show-SelectorPage -Page (New-SelectorHomePage -TaskState $taskState) }
                else { Start-SelectorScan }
            }
        }
    }
    finally { $app.Starting = $false }
}

function Get-SelectorFatalText {
    param([AllowEmptyString()][string]$Detail)

    try { return (Get-SelectorText -Key 'Gui.Fatal' -Arguments @("`r`n", $Detail)) }
    catch {
        return ('Windows 360 清理工具没能打开或者意外停止了。如果当时正在删除，不确定删了多少，请重启电脑后再检查一次。' + "`r`n" +
            'Windows 360 Cleaner could not start or stopped unexpectedly. If a deletion was running, it is not known how much was deleted; restart the PC and check again.' +
            "`r`n`r`n" + $Detail)
    }
}

function Show-SelectorFatalError {
    param([AllowEmptyString()][string]$Detail)

    $text = Get-SelectorFatalText -Detail $Detail
    try {
        Initialize-SelectorWinForms
        [void][Windows.Forms.MessageBox]::Show($text, 'Windows 360 Cleaner', [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Error)
    }
    catch {
        try { [Console]::Error.WriteLine($text) } catch {}
    }
}

if ($InternalTestLibraryOnly) {
    if ($env:WINDOWS_360_CLEANER_TEST_MODE -cne 'ISOLATED-SAFETY-TEST') {
        throw 'InternalTestLibraryOnly is reserved for the bundled isolated safety suite.'
    }
    if ($null -ne $script:SelectorLibraryLoadError) { throw $script:SelectorLibraryLoadError }
    return
}

$selectorExitCode = 0
$selectorMutex = $null
$selectorOwnsMutex = $false
try {
    if ($null -ne $script:SelectorLibraryLoadError) {
        throw ('The UI library could not be loaded ({0}): {1}' -f $script:SelectorLibraryPath,
            $script:SelectorLibraryLoadError.Exception.Message)
    }
    if ($env:OS -ne 'Windows_NT') { throw 'The interactive selector requires Windows.' }

    Initialize-SelectorWinForms
    [Windows.Forms.Application]::EnableVisualStyles()
    try { [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch {}
    try { [Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException) } catch {}

    $selectorMutex = New-Object System.Threading.Mutex($false, $script:SelectorMutexName)
    try { $selectorOwnsMutex = $selectorMutex.WaitOne(0, $false) }
    catch {
        if ($_.Exception -is [Threading.AbandonedMutexException] -or $_.Exception.InnerException -is [Threading.AbandonedMutexException]) {
            $selectorOwnsMutex = $true
        }
        else { throw }
    }
    if (-not $selectorOwnsMutex) {
        [void][Windows.Forms.MessageBox]::Show((Get-SelectorText -Key 'Ui.AlreadyRunning'),
            (Get-SelectorText -Key 'App.WindowTitle' -Arguments @($script:W360ToolVersion)),
            [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
    }
    else {
        if (-not [IO.File]::Exists($script:SelectorCoreScriptPath)) {
            throw "Cleanup script not found: $($script:SelectorCoreScriptPath)"
        }
        if ([string]::IsNullOrWhiteSpace($ReportDirectory)) {
            $selectorReportDirectory = Get-W360DefaultReportDirectory
        }
        else {
            $selectorReportDirectory = [IO.Path]::GetFullPath($ReportDirectory)
            if (-not [IO.Directory]::Exists($selectorReportDirectory)) {
                throw "Report directory does not exist: $selectorReportDirectory"
            }
        }

        $script:SelectorStartMode = $StartPage
        $script:SelectorApp = New-SelectorApp -ReportDirectory $selectorReportDirectory -CoreScriptPath $script:SelectorCoreScriptPath
        [Windows.Forms.Application]::add_ThreadException({
                param($sender, $threadErrorInfo)
                try { Show-SelectorUnexpectedError -ErrorRecord ([Management.Automation.ErrorRecord]::new($threadErrorInfo.Exception, 'SelectorThreadException', 'NotSpecified', $null)) }
                catch {}
            })
        $script:SelectorApp.Form.Add_Shown({
                Invoke-SelectorUiAction -SelectorAction { Invoke-SelectorStartup -Mode $script:SelectorStartMode }
            })
        [Windows.Forms.Application]::Run($script:SelectorApp.Form)
    }
}
catch {
    # 20 tells the root launcher that this window already showed its own error message.
    $selectorExitCode = 20
    Show-SelectorFatalError -Detail (Get-SelectorErrorRecordText -ErrorRecord $_)
}
finally {
    try {
        if ($null -ne $script:SelectorApp) {
            $script:SelectorApp.Timer.Stop()
            $script:SelectorApp.Timer.Dispose()
            if (-not $script:SelectorApp.Form.IsDisposed) { $script:SelectorApp.Form.Dispose() }
        }
    }
    catch {}
    if ($null -ne $selectorMutex) {
        try { if ($selectorOwnsMutex) { $selectorMutex.ReleaseMutex() } } catch {}
        $selectorMutex.Dispose()
    }
}
exit $selectorExitCode
