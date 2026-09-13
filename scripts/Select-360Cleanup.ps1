#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ReportDirectory,

    [switch]$InternalTestLibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$cleanupScript = Join-Path $PSScriptRoot 'Invoke-360Cleanup.ps1'
$script:IsChinese = [Globalization.CultureInfo]::CurrentUICulture.Name -match '^zh'
$script:ReportDirectory = $ReportDirectory

function Get-UiText {
    param([string]$Chinese, [string]$English)
    if ($script:IsChinese) { return $Chinese }
    return $English
}

function New-ReportPath {
    param([ValidateSet('Scan', 'Remove')] [string]$Mode)

    $directory = $script:ReportDirectory
    if (-not [string]::IsNullOrWhiteSpace($directory)) {
        $directory = [IO.Path]::GetFullPath($directory)
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Report directory does not exist: $directory"
        }
    }
    if ([string]::IsNullOrWhiteSpace($directory)) {
        $directory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    }
    if ([string]::IsNullOrWhiteSpace($directory)) { $directory = [IO.Path]::GetTempPath().TrimEnd('\') }
    return Join-Path $directory ('360-cleanup-{0}-{1:yyyyMMdd-HHmmss}-{2}.json' -f
        $Mode.ToLowerInvariant(), (Get-Date), ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
}

function ConvertTo-ProcessArgument {
    param([string]$Value)
    if ($Value -match '[\r\n"]') { throw 'A child-process argument contains an unsupported quote or newline.' }
    if ($Value -notmatch '\s') { return $Value }
    return '"' + $Value + '"'
}

function Invoke-CleanupProcess {
    param([string[]]$Parameters)

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cleanupScript) + $Parameters
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = (($arguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output   = ($stdout + $stderr).Trim()
    }
}

function Get-StrictJsonReport {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    return $utf8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
}

function Get-FileSha256 {
    param([string]$Path)

    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '') }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Test-FindingSelectable {
    param([object]$Finding)
    return $Finding.Confidence -eq 'Confirmed' -and -not [bool]$Finding.Offline -and
        $Finding.RemovalType -ne 'None' -and [string]$Finding.SelectionId -match '^[0-9A-Fa-f]{64}$'
}

if ($InternalTestLibraryOnly) {
    if ($env:WINDOWS_360_CLEANER_TEST_MODE -cne 'ISOLATED-SAFETY-TEST') {
        throw 'InternalTestLibraryOnly is reserved for the bundled isolated safety suite.'
    }
    return
}

if ($env:OS -ne 'Windows_NT') { throw 'The interactive selector requires Windows.' }
if (-not (Test-Path -LiteralPath $cleanupScript -PathType Leaf)) { throw "Cleanup script not found: $cleanupScript" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$scanReport = New-ReportPath -Mode Scan
$scanResult = Invoke-CleanupProcess -Parameters @('-Mode', 'Scan', '-ReportPath', $scanReport)
if ($scanResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $scanReport -PathType Leaf)) {
    [void][Windows.Forms.MessageBox]::Show(
        (Get-UiText "扫描失败，未进行任何删除。`r`n`r`n$($scanResult.Output)" "Scan failed. Nothing was removed.`r`n`r`n$($scanResult.Output)"),
        (Get-UiText 'Windows 360 清理技能' 'Windows 360 Cleaner Skill'),
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

try {
    $report = Get-StrictJsonReport -Path $scanReport
    $approvedReportHash = Get-FileSha256 -Path $scanReport
    if ([int]$report.SchemaVersion -ne 2 -or [string]$report.Mode -cne 'Scan' -or
        $approvedReportHash -notmatch '^[0-9A-F]{64}$') {
        throw 'The scan did not produce a valid SchemaVersion 2 approval report.'
    }
}
catch {
    [void][Windows.Forms.MessageBox]::Show(
        (Get-UiText "扫描报告无效，未进行任何删除。`r`n`r`n$($_.Exception.Message)" "The scan report is invalid. Nothing was removed.`r`n`r`n$($_.Exception.Message)"),
        (Get-UiText 'Windows 360 清理技能' 'Windows 360 Cleaner Skill'),
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Error
    )
    exit 1
}

$findings = @($report.Findings)
$seenSelectionIds = @{}
$displayFindings = New-Object System.Collections.ArrayList
foreach ($finding in @($findings | Sort-Object Confidence, Kind, Name, Target)) {
    if (Test-FindingSelectable $finding) {
        $id = ([string]$finding.SelectionId).ToUpperInvariant()
        if ($seenSelectionIds.ContainsKey($id)) { continue }
        $seenSelectionIds[$id] = $true
    }
    [void]$displayFindings.Add($finding)
}
$confirmedCount = @($displayFindings | Where-Object { Test-FindingSelectable $_ }).Count
$reviewCount = @($findings | Where-Object { -not (Test-FindingSelectable $_) }).Count

if ($findings.Count -eq 0) {
    [void][Windows.Forms.MessageBox]::Show(
        (Get-UiText "扫描完成，没有发现匹配项目。`r`n报告：$scanReport" "Scan complete. No matching items were found.`r`nReport: $scanReport"),
        (Get-UiText 'Windows 360 清理技能' 'Windows 360 Cleaner Skill'),
        [Windows.Forms.MessageBoxButtons]::OK,
        [Windows.Forms.MessageBoxIcon]::Information
    )
    exit 0
}

$form = New-Object Windows.Forms.Form
$form.Text = Get-UiText 'Windows 360 清理技能 — 选择要删除的项目' 'Windows 360 Cleaner Skill — Choose items to remove'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object Drawing.Size(1220, 760)
$form.MinimumSize = New-Object Drawing.Size(900, 600)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$heading = New-Object Windows.Forms.Label
$heading.AutoSize = $false
$heading.Location = New-Object Drawing.Point(18, 15)
$heading.Size = New-Object Drawing.Size(1165, 52)
$heading.Text = Get-UiText `
    "扫描完成：$confirmedCount 个可确认删除项目，$reviewCount 个仅供检查项目。默认一个都不选；黄色项目不能在这里删除。" `
    "Scan complete: $confirmedCount confirmed removable item(s), $reviewCount review-only item(s). Nothing is selected by default; yellow rows cannot be removed here."
$form.Controls.Add($heading)

$grid = New-Object Windows.Forms.DataGridView
$grid.Location = New-Object Drawing.Point(18, 72)
$grid.Size = New-Object Drawing.Size(1165, 565)
$grid.Anchor = 'Top,Bottom,Left,Right'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeRowsMode = 'AllCells'
$grid.SelectionMode = 'FullRowSelect'
$grid.EditMode = 'EditOnEnter'

$selectColumn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
$selectColumn.Name = 'Selected'
$selectColumn.HeaderText = Get-UiText '删除' 'Remove'
$selectColumn.Width = 58
[void]$grid.Columns.Add($selectColumn)

foreach ($definition in @(
    @{ Name = 'Confidence'; Header = (Get-UiText '安全级别' 'Status'); Width = 92 },
    @{ Name = 'Name'; Header = (Get-UiText '项目' 'Item'); Width = 190 },
    @{ Name = 'Kind'; Header = (Get-UiText '类型' 'Type'); Width = 82 },
    @{ Name = 'Target'; Header = (Get-UiText '目标' 'Target'); Width = 345 },
    @{ Name = 'Reason'; Header = (Get-UiText '判断依据' 'Reason'); Width = 370 }
)) {
    $column = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $definition.Name
    $column.HeaderText = $definition.Header
    $column.Width = $definition.Width
    $column.ReadOnly = $true
    $column.DefaultCellStyle.WrapMode = 'True'
    [void]$grid.Columns.Add($column)
}

foreach ($finding in @($displayFindings)) {
    $selectable = Test-FindingSelectable $finding
    $index = $grid.Rows.Add($false, $finding.Confidence, $finding.Name, $finding.Kind, $finding.Target, $finding.Reason)
    $row = $grid.Rows[$index]
    $row.Tag = $finding
    $row.Cells['Selected'].ReadOnly = -not $selectable
    if ($selectable) {
        $row.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(235, 248, 239)
    }
    else {
        $row.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(255, 248, 220)
        $row.DefaultCellStyle.ForeColor = [Drawing.Color]::DimGray
    }
}
$form.Controls.Add($grid)

$reportLabel = New-Object Windows.Forms.Label
$reportLabel.AutoEllipsis = $true
$reportLabel.Location = New-Object Drawing.Point(18, 646)
$reportLabel.Size = New-Object Drawing.Size(700, 35)
$reportLabel.Anchor = 'Bottom,Left,Right'
$reportLabel.Text = (Get-UiText '扫描报告：' 'Scan report: ') + $scanReport
$form.Controls.Add($reportLabel)

$selectAllButton = New-Object Windows.Forms.Button
$selectAllButton.Text = Get-UiText '全选可删除项' 'Select confirmed'
$selectAllButton.Location = New-Object Drawing.Point(18, 688)
$selectAllButton.Size = New-Object Drawing.Size(135, 30)
$selectAllButton.Anchor = 'Bottom,Left'
$selectAllButton.Add_Click({
    foreach ($row in $grid.Rows) {
        if (Test-FindingSelectable $row.Tag) { $row.Cells['Selected'].Value = $true }
    }
})
$form.Controls.Add($selectAllButton)

$clearButton = New-Object Windows.Forms.Button
$clearButton.Text = Get-UiText '清空选择' 'Clear selection'
$clearButton.Location = New-Object Drawing.Point(160, 688)
$clearButton.Size = New-Object Drawing.Size(110, 30)
$clearButton.Anchor = 'Bottom,Left'
$clearButton.Add_Click({
    foreach ($row in $grid.Rows) { $row.Cells['Selected'].Value = $false }
})
$form.Controls.Add($clearButton)

$keepButton = New-Object Windows.Forms.Button
$keepButton.Text = Get-UiText '只保留报告' 'Keep report only'
$keepButton.Location = New-Object Drawing.Point(790, 688)
$keepButton.Size = New-Object Drawing.Size(125, 30)
$keepButton.Anchor = 'Bottom,Right'
$keepButton.Add_Click({ $form.DialogResult = [Windows.Forms.DialogResult]::Cancel; $form.Close() })
$form.Controls.Add($keepButton)

$removeButton = New-Object Windows.Forms.Button
$removeButton.Text = Get-UiText '删除所选项目' 'Remove selected'
$removeButton.Location = New-Object Drawing.Point(925, 688)
$removeButton.Size = New-Object Drawing.Size(125, 30)
$removeButton.Anchor = 'Bottom,Right'
$removeButton.Enabled = $confirmedCount -gt 0
$removeButton.Add_Click({
    $selected = @($grid.Rows | Where-Object {
        (Test-FindingSelectable $_.Tag) -and [bool]$_.Cells['Selected'].Value
    } | ForEach-Object { $_.Tag })
    if ($selected.Count -eq 0) {
        [void][Windows.Forms.MessageBox]::Show(
            (Get-UiText '请先勾选至少一个绿色的 Confirmed 项目。' 'Select at least one green Confirmed item first.'),
            $form.Text, [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($selected.Count -gt 64) {
        [void][Windows.Forms.MessageBox]::Show(
            (Get-UiText '一次最多选择 64 项。请减少勾选，并在完成后重新扫描下一批。' 'Select at most 64 items per run. Choose fewer items, then run a fresh scan for the next batch.'),
            $form.Text, [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    $preview = @($selected | Select-Object -First 8 | ForEach-Object { '- ' + $_.Name }) -join "`r`n"
    if ($selected.Count -gt 8) { $preview += "`r`n... +$($selected.Count - 8)" }
    $question = Get-UiText `
        "将永久删除下面 $($selected.Count) 个已确认项目，不进入回收站：`r`n`r`n$preview`r`n`r`nReviewOnly 和未勾选项目会保留。厂商卸载器可能同时移除其所属产品的组件。是否继续？" `
        "The following $($selected.Count) confirmed item(s) will be permanently removed without using the Recycle Bin:`r`n`r`n$preview`r`n`r`nReviewOnly and unselected targets will be preserved. A selected vendor uninstaller can also remove components belonging to its product. Continue?"
    $answer = [Windows.Forms.MessageBox]::Show($question, $form.Text,
        [Windows.Forms.MessageBoxButtons]::YesNo, [Windows.Forms.MessageBoxIcon]::Warning,
        [Windows.Forms.MessageBoxDefaultButton]::Button2)
    if ($answer -ne [Windows.Forms.DialogResult]::Yes) { return }

    $form.Enabled = $false
    try {
        $removeReport = New-ReportPath -Mode Remove
        $ids = @($selected | ForEach-Object { [string]$_.SelectionId }) -join ';'
        $removeResult = Invoke-CleanupProcess -Parameters @(
            '-Mode', 'Remove', '-ConfirmRemoval', '-ConfirmationPhrase', 'REMOVE-CONFIRMED-360',
            '-ApprovedReport', $scanReport, '-ApprovedReportHash', $approvedReportHash,
            '-SelectedFindingIds', $ids, '-ReportPath', $removeReport
        )
        if (Test-Path -LiteralPath $removeReport -PathType Leaf) {
            $removeData = Get-StrictJsonReport -Path $removeReport
            $summary = $removeData.Summary
            $remainingText = if ($null -eq $summary.ImmediateRemainingSelected) {
                Get-UiText '未知（安全复扫未完成）' 'unknown (safe rescan incomplete)'
            }
            else { [string]$summary.ImmediateRemainingSelected }
            $message = Get-UiText `
                "删除流程结束。`r`n已选择：$($summary.SelectedConfirmedFindings)；保留未选择：$($summary.UnselectedConfirmedFindings)`r`n总计删除：$($summary.TotalItemsRemoved)`r`n文件：$($summary.FilesRemoved)；目录：$($summary.DirectoriesRemoved)`r`n逻辑大小：$($summary.LogicalSizeRemoved)`r`n失败操作：$($summary.FailedActions)`r`n所选项目仍残留：$remainingText`r`n`r`n报告：$removeReport" `
                "Removal finished.`r`nSelected: $($summary.SelectedConfirmedFindings); unselected preserved: $($summary.UnselectedConfirmedFindings)`r`nTotal removed: $($summary.TotalItemsRemoved)`r`nFiles: $($summary.FilesRemoved); directories: $($summary.DirectoriesRemoved)`r`nLogical size: $($summary.LogicalSizeRemoved)`r`nFailed actions: $($summary.FailedActions)`r`nSelected items still present: $remainingText`r`n`r`nReport: $removeReport"
            $icon = if ($removeResult.ExitCode -eq 0) { [Windows.Forms.MessageBoxIcon]::Information } else { [Windows.Forms.MessageBoxIcon]::Warning }
            [void][Windows.Forms.MessageBox]::Show($message, $form.Text, [Windows.Forms.MessageBoxButtons]::OK, $icon)
        }
        else {
            [void][Windows.Forms.MessageBox]::Show(
                (Get-UiText "删除未完成，未生成删除报告。`r`n`r`n$($removeResult.Output)" "Removal did not complete and no removal report was created.`r`n`r`n$($removeResult.Output)"),
                $form.Text, [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Error)
        }
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    }
    finally { $form.Enabled = $true }
})
$form.Controls.Add($removeButton)

$form.AcceptButton = $removeButton
$form.CancelButton = $keepButton
[void]$form.ShowDialog()
exit 0
