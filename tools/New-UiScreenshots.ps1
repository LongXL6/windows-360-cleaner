#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [int]$Width = 1100,
    [int]$Height = 720,
    [switch]$SkipExplorerCapture,
    [switch]$UseDrawToBitmap
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Maintainer tool: renders documentation screenshots of the guided window with SAMPLE data.
# - Reports are produced by the real read-only detector and verification functions on an isolated
#   temporary fixture, then the fixture folder is replaced with a neutral sample path for display.
# - It never calls Remove-ConfirmedFindings, never elevates, never runs a vendor uninstaller, and never
#   touches services, tasks, or the real registry. "Cleaning" in the story only deletes fixture folders
#   inside the temporary test directory.
# - Every image carries a visible banner saying it uses sample data.

$toolRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $toolRoot '..'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $repoRoot 'assets\screenshots' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$corePath = Join-Path $repoRoot 'scripts\Invoke-360Cleanup.ps1'
$selectorPath = Join-Path $repoRoot 'scripts\Select-360Cleanup.ps1'
. (Join-Path $repoRoot 'tests\Test-Helpers.ps1')

$previousTestMode = $env:WINDOWS_360_CLEANER_TEST_MODE
$env:WINDOWS_360_CLEANER_TEST_MODE = 'ISOLATED-SAFETY-TEST'
try {
    . $corePath -InternalTestLibraryOnly
    . $selectorPath -InternalTestLibraryOnly
}
finally {
    if ($null -eq $previousTestMode) { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
    else { $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode }
}

Initialize-SelectorWinForms
[Windows.Forms.Application]::EnableVisualStyles()
Set-W360UiLanguage -Language 'zh'
Set-SelectorFontScale -Scale 1.0

$script:SampleUserRoot = 'C:\Users\示例用户'
$script:SampleSid = [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:BannerText = '示例数据截图：只用于说明界面，没有检查或删除这台电脑上的任何真实内容'
$script:Captured = New-Object System.Collections.ArrayList
$script:StartEntryDescription = '解压后的文件夹：双击“开始检查”（真实的资源管理器文件列表，只截取文件列表区域；没有运行任何清理）'

Add-Type -Namespace Windows360CleanerTools -Name NativeWindow -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);
[DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr childAfter, string className, string windowName);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public static IntPtr FindDescendant(IntPtr parent, string className, int depth) {
    if (depth > 8) { return IntPtr.Zero; }
    IntPtr child = IntPtr.Zero;
    while (true) {
        child = FindWindowEx(parent, child, null, null);
        if (child == IntPtr.Zero) { return IntPtr.Zero; }
        System.Text.StringBuilder name = new System.Text.StringBuilder(256);
        GetClassName(child, name, name.Capacity);
        if (name.ToString() == className) { return child; }
        IntPtr found = FindDescendant(child, className, depth + 1);
        if (found != IntPtr.Zero) { return found; }
    }
}
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
'@

function Get-VisibleWindowRectangle {
    param([IntPtr]$Handle)

    $rect = New-Object Windows360CleanerTools.NativeWindow+RECT
    # DWMWA_EXTENDED_FRAME_BOUNDS (9) excludes the invisible resize border and shadow on Windows 10/11.
    $size = [Runtime.InteropServices.Marshal]::SizeOf([type][Windows360CleanerTools.NativeWindow+RECT])
    if ([Windows360CleanerTools.NativeWindow]::DwmGetWindowAttribute($Handle, 9, [ref]$rect, $size) -ne 0) {
        [void][Windows360CleanerTools.NativeWindow]::GetWindowRect($Handle, [ref]$rect)
    }
    return New-Object Drawing.Rectangle($rect.Left, $rect.Top, ($rect.Right - $rect.Left), ($rect.Bottom - $rect.Top))
}

function Save-ScreenRegion {
    param(
        [Drawing.Rectangle]$Rectangle,
        [string]$Path
    )

    $bitmap = New-Object Drawing.Bitmap($Rectangle.Width, $Rectangle.Height)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($Rectangle.Location, [Drawing.Point]::Empty, $Rectangle.Size)
        $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Add-SampleBanner {
    param([Windows.Forms.Form]$Form)

    $banner = New-Object Windows.Forms.Label
    $banner.Text = $script:BannerText
    $banner.Dock = [Windows.Forms.DockStyle]::Top
    $banner.AutoSize = $false
    $banner.Height = 28
    $banner.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
    $banner.BackColor = [Drawing.Color]::FromArgb(255, 214, 102)
    $banner.ForeColor = [Drawing.Color]::FromArgb(64, 40, 0)
    $banner.Font = Get-SelectorFont -Size 10 -Bold
    $banner.Name = 'SampleDataBanner'
    $Form.Controls.Add($banner)
    # Dock order follows reverse z-order: the back-most control is docked first, so it stays on top.
    $banner.SendToBack()
    $Form.Text = $Form.Text + '  【示例数据】'
}

function Save-FormScreenshot {
    param(
        [Windows.Forms.Form]$Form,
        [string]$Name,
        [string]$Description,
        [int]$FormWidth = $Width,
        [int]$FormHeight = $Height,
        # Runs after the window is shown (for example to make a list row current), before the capture.
        [scriptblock]$AfterShown
    )

    Add-SampleBanner -Form $Form
    $Form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $Form.Location = New-Object Drawing.Point(60, 60)
    $Form.Size = New-Object Drawing.Size($FormWidth, $FormHeight)
    $Form.ShowInTaskbar = $false
    $Form.TopMost = $true
    $path = Join-Path $OutputDirectory ($Name + '.png')
    try {
        $Form.Show()
        for ($i = 0; $i -lt 8; $i++) {
            [Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 60
        }
        if ($null -ne $AfterShown) {
            & $AfterShown
            for ($i = 0; $i -lt 4; $i++) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 60
            }
        }
        if ($UseDrawToBitmap) {
            $bitmap = New-Object Drawing.Bitmap($Form.Width, $Form.Height)
            try {
                $Form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)))
                $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
            }
            finally { $bitmap.Dispose() }
        }
        else {
            [void][Windows360CleanerTools.NativeWindow]::SetForegroundWindow($Form.Handle)
            $Form.Activate()
            for ($i = 0; $i -lt 6; $i++) {
                [Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 80
            }
            Save-ScreenRegion -Rectangle (Get-VisibleWindowRectangle -Handle $Form.Handle) -Path $path
        }
    }
    finally {
        $Form.Close()
        $Form.Dispose()
    }
    [void]$script:Captured.Add([pscustomobject]@{ Name = $Name + '.png'; Description = $Description })
    Write-Host ("Saved {0}" -f $path)
}

function Save-PageScreenshot {
    param(
        [scriptblock]$Build,
        [string]$Name,
        [string]$Description,
        # Receives the page after the window is shown.
        [scriptblock]$AfterShown
    )

    $shell = New-SelectorMainForm
    $page = & $Build
    Set-SelectorPage -Shell $shell -Page $page
    $script:ScreenshotPage = $page
    $afterShownBlock = $null
    if ($null -ne $AfterShown) {
        $pageAction = $AfterShown
        $afterShownBlock = { & $pageAction $script:ScreenshotPage }
    }
    Save-FormScreenshot -Form $shell.Form -Name $Name -Description $Description -AfterShown $afterShownBlock
}

function New-SampleFixture {
    param([string]$Root)

    $folders = [ordered]@{
        LocalAppData    = Join-Path $Root 'AppData\Local'
        RoamingAppData  = Join-Path $Root 'AppData\Roaming'
        ProgramFiles    = Join-Path $Root 'Program Files'
        ProgramFilesX86 = Join-Path $Root 'Program Files (x86)'
        ProgramData     = Join-Path $Root 'ProgramData'
        UserProfile     = $Root
        Desktop         = Join-Path $Root 'Desktop'
        Temp            = Join-Path $Root 'AppData\Local\Temp'
        Windows         = Join-Path $Root 'Windows'
    }
    foreach ($path in $folders.Values) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $script:KnownFolders = $folders
    $script:CurrentUserRegistryRoot = 'HKCU:'

    $duohuiRoot = Join-Path $folders.LocalAppData 'dhpingbao'
    New-Item -ItemType Directory -Path $duohuiRoot -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $duohuiRoot 'duohuipingbao.exe') -Value 'SAMPLE'
    Set-Content -LiteralPath (Join-Path $duohuiRoot 'qcnethelp64.dll') -Value 'SAMPLE'
    $duohuiTemp = Join-Path $folders.Temp 'duohuipingbao'
    New-Item -ItemType Directory -Path (Join-Path $duohuiTemp '360hb_tmp') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $duohuiTemp 'huabaosetup.exe') -Value 'SAMPLE'

    $browserApplication = Join-Path $folders.RoamingAppData '360se6\Application'
    New-Item -ItemType Directory -Path $browserApplication -Force | Out-Null
    $browserExe = Join-Path $browserApplication '360se.exe'
    Set-Content -LiteralPath $browserExe -Value 'SAMPLE'
    $profile = Join-Path $folders.RoamingAppData '360se6\User Data'
    New-Item -ItemType Directory -Path $profile -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $profile 'Bookmarks') -Value 'SAMPLE'
    New-Item -ItemType Directory -Path (Join-Path $folders.Temp '360UnPackTmp64') -Force | Out-Null

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $registryValues = @{}
    $registryValues[$runKey] = [pscustomobject]@{ duohuipingbao = ('"{0}" /autorun' -f (Join-Path $duohuiRoot 'duohuipingbao.exe')) }
    $tasks = @([pscustomobject]@{
        TaskName = '360画报更新'; TaskPath = '\'
        Actions = @([pscustomobject]@{ Execute = 'C:\SampleTools\updater.exe'; Arguments = ''; WorkingDirectory = '' })
    })
    return [pscustomobject]@{
        Folders = $folders; DuohuiRoot = $duohuiRoot; DuohuiTemp = $duohuiTemp; BrowserExe = $browserExe
        BrowserApplication = $browserApplication; RegistryValues = $registryValues; Tasks = $tasks
    }
}

function Invoke-SampleScan {
    param(
        [object]$Fixture,
        [bool]$IncludeStartup = $true
    )

    $registryValues = if ($IncludeStartup) { $Fixture.RegistryValues } else { @{} }
    $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($Fixture.BrowserExe) `
        -RegistryValues $registryValues -ScheduledTasks $Fixture.Tasks
    Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
    try {
        $findings = @(Get-360Findings)
        $coverage = Get-360ScanCoverage
    }
    finally { Reset-360CleanupRuntimeProvider }
    $findings = @(Add-CleanupSelectionIds -Findings $findings -UserSid $script:SampleSid)
    return [pscustomobject]@{ Findings = $findings; Coverage = $coverage; Fake = $fake }
}

function Write-DisplayCopy {
    param(
        [object]$Report,
        [string]$FixtureRoot,
        [string]$Directory,
        [string]$Kind
    )

    $json = $Report | ConvertTo-Json -Depth 10
    $escapedFixture = $FixtureRoot.Replace('\', '\\')
    $escapedSample = $script:SampleUserRoot.Replace('\', '\\')
    $json = [regex]::Replace($json, [regex]::Escape($escapedFixture), $escapedSample.Replace('$', '$$'), 'IgnoreCase')
    $path = New-W360ReportPath -Directory $Directory -Kind $Kind
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding($false)))
    return $path
}

function New-FakeChildState {
    param(
        [string[]]$Phases,
        [TimeSpan]$Elapsed
    )

    $events = New-Object System.Collections.ArrayList
    foreach ($phase in $Phases) { [void]$events.Add([pscustomobject]@{ Phase = $phase; Detail = '' }) }
    return [pscustomobject]@{ Events = $events; Elapsed = $Elapsed }
}

function Save-ExplorerScreenshot {
    param([string]$PackageFolder)

    $shell = New-Object -ComObject Shell.Application
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $PackageFolder) | Out-Null
    $window = $null
    # The package folder has a fresh random name, so matching its path is enough. Windows 11 may open
    # it as a tab inside an existing Explorer window that shares the same HWND, so HWNDs are not compared.
    for ($i = 0; $i -lt 150 -and $null -eq $window; $i++) {
        Start-Sleep -Milliseconds 200
        foreach ($candidate in @($shell.Windows())) {
            try {
                $location = [string]$candidate.Document.Folder.Self.Path
                if ($location.Equals($PackageFolder, [StringComparison]::OrdinalIgnoreCase)) { $window = $candidate; break }
            }
            catch {}
        }
    }
    if ($null -eq $window) { throw 'The Explorer window for the sample package did not open.' }
    $handle = [IntPtr][int64]$window.HWND
    try {
        # Details view makes the file names and types readable in the screenshot.
        try { $window.Document.CurrentViewMode = 4 } catch {}
        [void][Windows360CleanerTools.NativeWindow]::SetWindowPos($handle, [IntPtr](-1), 60, 60, 1000, 760, 0x0040)
        [void][Windows360CleanerTools.NativeWindow]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 1200
        try {
            $entry = $window.Document.Folder.ParseName('开始检查.cmd')
            # 1 select + 4 deselect others + 8 ensure visible + 16 focus
            if ($null -ne $entry) { $window.Document.SelectItem($entry, 29) }
        }
        catch {}
        Start-Sleep -Milliseconds 800
        $path = Join-Path $OutputDirectory '01-start-entry.png'
        $windowRect = Get-VisibleWindowRectangle -Handle $handle
        # Capture only the folder contents column: the navigation pane and preview pane show the
        # maintainer's own folders and drives, which must never appear in published screenshots.
        $defView = [Windows360CleanerTools.NativeWindow]::FindDescendant($handle, 'SHELLDLL_DefView', 0)
        if ($defView -eq [IntPtr]::Zero) { throw 'The Explorer file list could not be located; refusing to capture the whole window.' }
        $listRect = New-Object Windows360CleanerTools.NativeWindow+RECT
        [void][Windows360CleanerTools.NativeWindow]::GetWindowRect($defView, [ref]$listRect)
        $cropLeft = [Math]::Max($windowRect.Left, $listRect.Left)
        $cropRight = [Math]::Min($windowRect.Right, $listRect.Right)
        $cropTop = $listRect.Top
        $cropBottom = $listRect.Bottom
        if (($cropRight - $cropLeft) -lt 300 -or ($cropBottom - $cropTop) -lt 200) { throw 'The Explorer file list is too small to capture.' }
        Save-ScreenRegion -Rectangle (New-Object Drawing.Rectangle($cropLeft, $cropTop, ($cropRight - $cropLeft), ($cropBottom - $cropTop))) -Path $path
        [void]$script:Captured.Add([pscustomobject]@{ Name = '01-start-entry.png'; Description = $script:StartEntryDescription })
        Write-Host ("Saved {0}" -f $path)
    }
    finally {
        [void][Windows360CleanerTools.NativeWindow]::SetWindowPos($handle, [IntPtr](-2), 0, 0, 0, 0, 0x0003)
        try { $window.Quit() } catch { [void][Windows360CleanerTools.NativeWindow]::PostMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
    }
}

$fixtureRoot = New-TestDirectory
$originalKnownFolders = $script:KnownFolders
try {
    $reportDirectory = Join-Path $fixtureRoot 'reports'
    New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null
    $sampleRoot = Join-Path $fixtureRoot 'sample-user'
    $fixture = New-SampleFixture -Root $sampleRoot

    if (-not $SkipExplorerCapture) {
        $buildScript = Join-Path $repoRoot 'tools\Build-Release.ps1'
        $zipDirectory = Join-Path $fixtureRoot 'zip'
        New-Item -ItemType Directory -Path $zipDirectory -Force | Out-Null
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $buildScript -OutputDirectory $zipDirectory | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'The release build for the start-entry screenshot failed.' }
        $zip = @(Get-ChildItem -LiteralPath $zipDirectory -Filter '*.zip')[0]
        $publicRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDocuments)) ('W360-screenshot-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $publicRoot | Out-Null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $publicRoot)
            $packageFolder = @(Get-ChildItem -LiteralPath $publicRoot -Directory)[0].FullName
            Save-ExplorerScreenshot -PackageFolder $packageFolder
        }
        finally {
            Start-Sleep -Milliseconds 500
            $leaf = Split-Path -Leaf $publicRoot
            if ($leaf -match '^W360-screenshot-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $publicRoot)) {
                Remove-Item -LiteralPath $publicRoot -Recurse -Force
            }
        }
    }
    elseif (Test-Path -LiteralPath (Join-Path $OutputDirectory '01-start-entry.png') -PathType Leaf) {
        # Keep the earlier Explorer capture listed when only the sample-data pages are regenerated.
        [void]$script:Captured.Add([pscustomobject]@{ Name = '01-start-entry.png'; Description = $script:StartEntryDescription })
        Write-Host 'Kept the existing 01-start-entry.png (Explorer capture skipped).'
    }

    # 02 - check progress (simulated phase sequence of a read-only scan)
    Save-PageScreenshot -Name '02-scan-progress' -Description '检查进行中：只显示当前这一步和已用时间；检查不会删除任何东西，可以随时点“停止检查”' -Build {
        $page = New-SelectorProgressPage -Kind Scan
        Update-SelectorProgressPage -Page $page -State (New-FakeChildState -Elapsed ([TimeSpan]::FromSeconds(23)) -Phases @(
            'ScanStart', 'ScanProductFolders', 'ScanVendorUninstaller', 'ScanToolbox', 'ScanInstalledPrograms', 'ScanRegistryResidue', 'ScanStartup', 'ScanScheduledTasks'))
        $page
    }

    # 03 - scan results from the real detector on the sample fixture
    $scan = Invoke-SampleScan -Fixture $fixture
    $scanReport = [pscustomobject][ordered]@{
        SchemaVersion = 2; ToolVersion = $script:ToolVersion; Timestamp = (Get-Date).ToString('o'); ComputerName = $null; User = $null
        Mode = 'Scan'; ApprovalContext = [pscustomobject]@{ UserSid = $script:SampleSid }; ApprovedReportHash = $null; OutcomeRunId = $null
        Summary = $null; ScanCoverage = $scan.Coverage; Findings = @($scan.Findings); Actions = @()
    }
    $scanDisplayPath = Write-DisplayCopy -Report $scanReport -FixtureRoot $sampleRoot -Directory $reportDirectory -Kind 'scan'
    $scanOutcome = Get-W360ScanOutcome -ExitCode 0 -ReportPath $scanDisplayPath -StdoutLines @() -StderrLines @()
    $duohuiIds = @($scanOutcome.Findings | Where-Object {
        (Test-W360FindingDeletable -Finding $_ -Effective $scanOutcome.EffectiveDeletable) -and [string]$_.ProductKey -eq 'Duohui'
    } | ForEach-Object { [string]$_.SelectionId })
    $browserFinding = @($scanOutcome.Findings | Where-Object { [string]$_.Name -eq '360se6 browser application' })[0]
    if ($null -eq $browserFinding) { throw 'The sample scan did not find the 360 Secure Browser program files.' }
    $browserId = [string]$browserFinding.SelectionId
    if ($duohuiIds.Count -lt 1 -or [string]::IsNullOrWhiteSpace($browserId)) { throw 'The sample scan is missing the items the screenshots show.' }
    # Products start collapsed; the picture opens the two products it talks about. Only the Duohui group is ticked
    # (the same shrink-only toggle as a click on its checkbox), so 360 Secure Browser stays kept.
    Save-PageScreenshot -Name '03-scan-results' -Description '检查结果：按软件分组，每一行只回答“删不删”；打开时一个都不勾选（图中演示了只勾选 360 画报 / 多绘屏保，360 安全浏览器没有勾选、会保留）；下方说明区解释当前这一行，删除后会怎样' -Build {
        $page = New-SelectorScanResultPage -Outcome $scanOutcome
        if ($page.Data['Selection'].Count -ne 0) { throw 'The scan result page must open with nothing selected.' }
        $groupRows = @{}
        foreach ($groupInfo in @($page.Data['Groups'])) { $groupRows[[string]$groupInfo.Group.Key] = [int]$groupInfo.HeaderIndex }
        foreach ($key in @('Duohui', '360SafeBrowser')) {
            if (-not $groupRows.ContainsKey($key)) { throw "The sample scan has no $key product row." }
            [void](Switch-SelectorGroupCollapse -Page $page -RowIndex $groupRows[$key])
        }
        [void](Switch-SelectorGroupSelection -Page $page -RowIndex $groupRows['Duohui'])
        $selected = @(Get-SelectorSelectedIds -Page $page | Sort-Object)
        $expected = @($duohuiIds | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object)
        if (($selected -join ',') -ne ($expected -join ',')) { throw 'The Duohui product click did not tick exactly the Duohui items.' }
        if ($page.Data['Selection'].ContainsKey($browserId)) { throw 'The sample must keep 360 Secure Browser unticked.' }
        $page
    } -AfterShown {
        param($page)
        foreach ($row in $page.Grid.Rows) {
            if ([string]$row.Tag.Type -eq 'Finding' -and [string]$row.Tag.Finding.Name -eq 'Duohui screen saver') {
                $page.Grid.CurrentCell = $row.Cells[1]
                $page.Grid.ClearSelection()
                $row.Selected = $true
                Update-SelectorScanDetail -Page $page -RowIndex $row.Index
                $page.Grid.FirstDisplayedScrollingRowIndex = [int]$row.Tag.GroupInfo.HeaderIndex
                break
            }
        }
    }

    # 04 - confirmation dialog for the Duohui group only (360 Secure Browser kept)
    $plan = Get-W360SelectionPlan -Findings $scanOutcome.Findings -SelectedIds $duohuiIds
    if (-not $plan.CanSubmit) { throw 'The sample selection plan is not submittable.' }
    $confirm = New-SelectorConfirmDialog -Plan $plan -AllFindings @($scanOutcome.Findings)
    $confirmDescription = if ([bool]$plan.VendorUninstallerSelected) {
        '删除前确认：列出要删除的内容、删除后会怎样和会保留的内容，并提醒 360 自带的卸载程序可能删掉没选的部分；默认按钮是“取消”，要点红色的“删除”才会删除'
    }
    else {
        '删除前确认：列出要删除的内容、删除后会怎样和会保留的内容（360 安全浏览器没选，会保留）；默认按钮是“取消”，要点红色的“删除”才会删除'
    }
    Save-FormScreenshot -Form $confirm.Data['Form'] -Name '04-confirm-delete' -FormWidth 900 -FormHeight 640 -Description $confirmDescription

    # 05 - cleanup result: simulate removal of the fixture folders only, then use the core summary logic
    $comparison = Compare-ApprovedCleanupFindings -Approved $scan.Findings -Current $scan.Findings -SID $script:SampleSid
    $resolved = Resolve-CleanupSelection -Approved $scan.Findings -Eligible @($comparison.Eligible) -Current $scan.Findings `
        -SelectedIds $duohuiIds -UserSid $script:SampleSid -SelectionApplied $true
    $selection = New-360CleanupSelectionRecord -SelectionApplied $true -ApprovedReportPath $scanDisplayPath `
        -ApprovedReportHash (Get-W360FileSha256 -Path $scanDisplayPath) -SelectedIds $duohuiIds -ResolvedSelection $resolved `
        -ApprovalComparison $comparison -UserSid $script:SampleSid
    Remove-Item -LiteralPath $fixture.DuohuiRoot -Recurse -Force
    Remove-Item -LiteralPath $fixture.DuohuiTemp -Recurse -Force
    $afterRemove = Invoke-SampleScan -Fixture $fixture -IncludeStartup $false
    Set-360CleanupRuntimeProvider -Provider $afterRemove.Fake.Provider -Context $afterRemove.Fake.Context
    try {
        $summary = [ordered]@{
            TotalItemsRemoved = 9; FilesRemoved = 3; DirectoriesRemoved = 3; LogicalBytesRemoved = 5120; LogicalSizeRemoved = '5.00 KB'
            PathTargetsRemoved = 2; PartiallyCleanedPathTargets = 0; ServicesRemoved = 0; ServicesPendingRemoval = 0
            ScheduledTasksRemoved = 0; RegistryKeysRemoved = 0; RegistryValuesRemoved = 1; ProcessesStopped = 0
            VendorUninstallersSucceeded = 0; VendorUninstallersFailed = 0; VendorUninstallersPending = 0; SkippedActions = 0
            FailedActions = 0; PendingActions = 0; RetryAttempts = 0; UnresolvedRetryTargets = 0; AccessDeniedPathTargets = 0
            AclRepairAttempts = 0; AclRepairFailures = 0; UnresolvedPathTargets = 0; PathAccountingComplete = $true
            UnmeasuredPathTargets = 0; PostVendorMutationBlocked = $false
        }
        [void](Complete-360CleanupRemovalSummary -Summary $summary -ApprovalComparison $comparison -ResolvedSelection $resolved `
            -SelectionRecord $selection -SelectionApplied $true -RescanComplete $true -RemainingFindings $afterRemove.Findings `
            -UserSid $script:SampleSid -ApprovedReportHash (Get-W360FileSha256 -Path $scanDisplayPath))
    }
    finally { Reset-360CleanupRuntimeProvider }
    $now = Get-Date
    $actions = @(
        [pscustomobject]@{ Time = $now.ToString('o'); Action = 'DeleteRegistryValue'; Target = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run :: duohuipingbao'; Result = 'Success'; Detail = '' },
        [pscustomobject]@{ Time = $now.ToString('o'); Action = 'DeletePath'; Target = $fixture.DuohuiRoot; Result = 'Success'; Detail = 'Permanently removed; not sent to Recycle Bin.' },
        [pscustomobject]@{ Time = $now.ToString('o'); Action = 'DeletePath'; Target = $fixture.DuohuiTemp; Result = 'Success'; Detail = 'Permanently removed; not sent to Recycle Bin.' }
    )
    $scanHash = Get-W360FileSha256 -Path $scanDisplayPath
    $removeReport = [pscustomobject][ordered]@{
        SchemaVersion = 2; ToolVersion = $script:ToolVersion; Timestamp = $now.ToString('o'); ComputerName = $null; User = $null
        Mode = 'Remove'; ApprovalContext = [pscustomobject]@{ UserSid = $script:SampleSid }; ApprovedReportHash = $scanHash
        OutcomeRunId = [Guid]::NewGuid().ToString('N'); Summary = [pscustomobject]$summary; ScanCoverage = $afterRemove.Coverage
        Selection = $selection; Findings = @($afterRemove.Findings); Actions = $actions
    }
    $removeDisplayPath = Write-DisplayCopy -Report $removeReport -FixtureRoot $sampleRoot -Directory $reportDirectory -Kind 'remove'
    $removeOutcome = Get-W360RemoveOutcome -ExitCode 0 -ReportPath $removeDisplayPath -ExpectedApprovedReportHash $scanHash `
        -Events @() -StdoutLines @() -StderrLines @() -SelectedFindings @($plan.SelectedFindings)
    if ([string]$removeOutcome.State -ne 'Completed') { throw "The sample deletion result is not complete: $($removeOutcome.State)" }
    Save-PageScreenshot -Name '05-cleanup-result' -Description '删除结果：大标题说明删掉了没有，下面一行告诉你接下来怎么做；统计数字和操作记录放在“详细信息”里' -Build {
        New-SelectorRemoveResultPage -Outcome $removeOutcome
    }

    # 06 - home page after a restart
    $taskPath = New-W360TaskRecord -Directory $reportDirectory -ScanReportPath $scanDisplayPath -ScanReportHash $scanHash `
        -RemoveReportPath $removeDisplayPath -SelectedFindings @($scanOutcome.Findings | Where-Object { $duohuiIds -contains [string]$_.SelectionId }) `
        -PreservedFindings @($browserFinding)
    $taskInfo = Find-W360LatestTask -Directory $reportDirectory
    $taskState = Get-W360TaskState -TaskInfo $taskInfo -LastBootTime ($now.AddMinutes(5))
    Save-PageScreenshot -Name '06-home-after-restart' -Description '重启后再次打开：找到上次删除的记录，点“检查上次删除的结果”确认删干净了（检查不会删除任何东西）' -Build {
        New-SelectorHomePage -TaskState $taskState
    }

    # 07 - verification of the task: Duohui cleared, 360 Secure Browser kept by choice
    $verifyFake = New-Fake360CleanupRuntimeProvider -UseRealPathReads -ProductEvidencePaths @($fixture.BrowserExe) -ScheduledTasks $fixture.Tasks
    $realRemovePath = Join-Path $reportDirectory 'fixture-remove-for-verify.json'
    $fixtureRemoveReport = $removeReport
    [IO.File]::WriteAllText($realRemovePath, ($fixtureRemoveReport | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
    Set-360CleanupRuntimeProvider -Provider $verifyFake.Provider -Context $verifyFake.Context
    try {
        $verifyFindings = @(Add-CleanupSelectionIds -Findings @(Get-360Findings) -UserSid $script:SampleSid)
        $verifyCoverage = Get-360ScanCoverage
        $previous = Read-360CleanupPreviousRemoveReport -Path $realRemovePath -CurrentUserSid $script:SampleSid
        $taskVerification = Get-360CleanupTaskVerification -Previous $previous -CurrentFindings $verifyFindings -UserSid $script:SampleSid
    }
    finally { Reset-360CleanupRuntimeProvider }
    foreach ($operation in @('RemovePath', 'RepairPathAcl', 'StopProcess', 'StartVendorUninstaller', 'StartElevatedProcess')) {
        if (@(Get-Fake360CleanupCalls -Fake $verifyFake -Operation $operation).Count -ne 0) { throw "Sample verification reached $operation." }
    }
    $verifyExit = Get-360CleanupVerifyExitCode -Findings $verifyFindings -Coverage $verifyCoverage -TaskVerification $taskVerification
    $verifyReport = [pscustomobject][ordered]@{
        SchemaVersion = 2; ToolVersion = $script:ToolVersion; Timestamp = $now.AddMinutes(6).ToString('o'); ComputerName = $null; User = $null
        Mode = 'Verify'; ApprovalContext = $null; ApprovedReportHash = $null; OutcomeRunId = $null; Summary = $null
        ScanCoverage = $verifyCoverage; TaskVerification = $taskVerification; Findings = @($verifyFindings); Actions = @()
    }
    $verifyDisplayPath = Write-DisplayCopy -Report $verifyReport -FixtureRoot $sampleRoot -Directory $reportDirectory -Kind 'verify'
    $verifyOutcome = Get-W360VerifyOutcome -ExitCode $verifyExit -ReportPath $verifyDisplayPath -StdoutLines @() -StderrLines @()
    if ($verifyOutcome.State -ne 'TaskCompleted') { throw "The sample verification did not complete: $($verifyOutcome.State)" }
    Save-PageScreenshot -Name '07-verify-result' -Description '检查上次删除的结果：多绘屏保已删掉，360 安全浏览器按你的选择保留着，不算删除失败' -Build {
        New-SelectorVerifyResultPage -Outcome $verifyOutcome
    }

    $readme = New-Object System.Collections.Generic.List[string]
    $readme.Add('# 界面截图（示例数据）')
    $readme.Add('')
    $readme.Add('这些截图由 `tools/New-UiScreenshots.ps1` 生成，工具版本 ' + $script:W360ToolVersion + '。02–07 使用示例数据，每张图顶部都有“示例数据截图”横幅；01 是真实的资源管理器文件列表，只显示打包后的文件，不含任何检查数据。')
    $readme.Add('数据来自在隔离的临时示例目录上运行的检查逻辑（不会删除任何东西）；显示路径已替换为 `C:\Users\示例用户`。生成过程没有检查或删除这台电脑上的真实软件，也没有弹出 Windows 的权限窗口。')
    $readme.Add('')
    $readme.Add('| 文件 | 内容 |')
    $readme.Add('|---|---|')
    foreach ($item in $script:Captured) { $readme.Add(('| `{0}` | {1} |' -f $item.Name, $item.Description)) }
    $readme.Add('')
    $readme.Add('Screenshots use sample data. They were produced from an isolated temporary fixture with read-only detection and verification logic; nothing on a real PC was scanned or removed.')
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'README.md'), (($readme.ToArray() -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
    Write-Host ("Screenshots written to {0}" -f $OutputDirectory) -ForegroundColor Green
}
finally {
    Reset-360CleanupRuntimeProvider
    $script:KnownFolders = $originalKnownFolders
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) { Remove-TestDirectory -Path $fixtureRoot }
}
