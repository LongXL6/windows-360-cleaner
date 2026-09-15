#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty inside param() defaults under powershell.exe -File in Windows PowerShell 5.1.
if ([string]::IsNullOrWhiteSpace($CleanerScriptPath)) {
    $CleanerScriptPath = Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1'
}

# Packaging tests only read the repository and write inside New-TestDirectory fixtures.
# They never launch the real selector GUI, never run the core in Remove mode and never publish anything.

$packagingTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

Add-Type -AssemblyName System.IO.Compression

$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:CoreScriptPath = [IO.Path]::GetFullPath($CleanerScriptPath)
$script:LibraryScriptPath = Join-Path (Split-Path -Parent $script:CoreScriptPath) 'Windows360Cleaner.Library.ps1'
$script:BuildScriptPath = Join-Path $script:RepositoryRoot 'tools\Build-Release.ps1'
$script:TemplatePath = Join-Path $script:RepositoryRoot 'packaging\使用说明.txt'
$script:LauncherNames = @('开始检查.cmd', 'Start-Check.cmd')
$script:LauncherTestVariable = 'WINDOWS_360_CLEANER_LAUNCHER_TEST'
$script:LauncherTestMarker = 'W360-LAUNCHER-TEST: MissingProgramFiles'
$script:DummySelectorMarker = 'W360-DUMMY-SELECTOR|'
$script:MissingFilesChineseText = '没有找到 scripts 文件夹中的程序文件。请先在下载的 ZIP 上点右键，选“全部解压缩”（有的电脑显示为“全部解压”），再在解压出来的文件夹里双击“开始检查”。'
# The could-not-run message uses the window's plain words: a deletion that was running is "not sure", never finished.
$script:FailedChineseTexts = @('Windows PowerShell 没能正常运行清理工具', '如果当时正在删除，不确定有没有删干净。', '请重启电脑后，再双击“开始检查”，点“检查上次删除的结果”',
    '请不要为了运行本工具关掉安全软件。', 'Scan-360.cmd')
$script:FailedEnglishTexts = @('If something was being deleted at that moment, it is not certain that everything was deleted.', 'click "Check the last deletion"',
    'Do not turn off your security software')
$script:LauncherOldWords = @('复检', '清理，结果未知', '结果未知', '扫描', '报告', 'verify again', 'cleanup was running')
$script:NormalLauncherCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\Select-360Cleanup.ps1"'
$script:RequiredPackageFiles = @(
    '开始检查.cmd', 'Start-Check.cmd', '使用说明.txt', 'README.md', 'README.en.md', 'SKILL.md', 'LICENSE',
    'CHANGELOG.md', 'VERSION', 'scripts/Invoke-360Cleanup.ps1', 'scripts/Select-360Cleanup.ps1',
    'scripts/Windows360Cleaner.Library.ps1', 'scripts/Show-360Summary.ps1'
)
$script:RequiredPackageFolders = @('agents/', 'scripts/', 'tests/', 'references/', 'assets/readme/')
$script:AllowedPackageTopLevel = @(
    '开始检查.cmd', 'Start-Check.cmd', '使用说明.txt', 'README.md', 'README.en.md', 'SKILL.md', 'LICENSE',
    'CHANGELOG.md', 'VERSION', 'agents', 'scripts', 'tests', 'references', 'assets'
)
$script:PackagingJunctions = New-Object System.Collections.ArrayList

function Test-PackagingUtf8Bom {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function ConvertFrom-PackagingUtf8 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $offset = 0
    if (Test-PackagingUtf8Bom -Bytes $Bytes) { $offset = 3 }
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    return $strict.GetString($Bytes, $offset, $Bytes.Length - $offset)
}

function Assert-PackagingAsciiCrlf {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-TestTrue ($Bytes.Length -gt 0) "$Label is empty."
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        $byte = $Bytes[$index]
        if ($byte -ge 0x80) { throw ('{0} must be ASCII-only; byte 0x{1:X2} found at offset {2}.' -f $Label, $byte, $index) }
        if ($byte -eq 0x0A -and ($index -eq 0 -or $Bytes[$index - 1] -ne 0x0D)) { throw "$Label must use CRLF line endings (bare LF found)." }
        if ($byte -eq 0x0D -and ($index + 1 -ge $Bytes.Length -or $Bytes[$index + 1] -ne 0x0A)) { throw "$Label must use CRLF line endings (bare CR found)." }
    }
}

function Assert-PackagingCrlfText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-TestFalse ([regex]::IsMatch($Text, "(?<!\r)\n|\r(?!\n)")) "$Label must use CRLF line endings."
}

function Write-PackagingFixtureFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [AllowEmptyString()][string]$Text = '',
        [byte[]]$Bytes,
        [switch]$PowerShellSource
    )

    $path = Join-Path $Root ($RelativePath.Replace('/', '\'))
    $parent = Split-Path -Parent $path
    if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
    if ($PSBoundParameters.ContainsKey('Bytes')) {
        [IO.File]::WriteAllBytes($path, $Bytes)
    }
    elseif ($PowerShellSource) {
        [IO.File]::WriteAllText($path, [regex]::Replace($Text, "\r\n|\r|\n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
    }
    else {
        [IO.File]::WriteAllText($path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
}

function Copy-PackagingRepositoryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $source = Join-Path $script:RepositoryRoot ($RelativePath.Replace('/', '\'))
    Write-PackagingFixtureFile -Root $Root -RelativePath $RelativePath -Bytes ([IO.File]::ReadAllBytes($source))
}

function New-PackagingJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    [void]$script:PackagingJunctions.Add($Path)
}

function New-PackagingFixture {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$OutsideDirectory
    )

    [void][IO.Directory]::CreateDirectory($Root)
    [void][IO.Directory]::CreateDirectory($OutsideDirectory)
    Write-PackagingFixtureFile -Root $OutsideDirectory -RelativePath 'outside-secret.txt' -Text 'OUTSIDE-CANARY-MUST-NOT-BE-PACKAGED'

    foreach ($relativePath in @('开始检查.cmd', 'Start-Check.cmd', 'scripts/Scan-360.cmd', 'scripts/Verify-360.cmd', 'packaging/使用说明.txt')) {
        Copy-PackagingRepositoryFile -Root $Root -RelativePath $relativePath
    }

    Write-PackagingFixtureFile -Root $Root -RelativePath 'VERSION' -Text ($Version + "`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'CHANGELOG.md' -Text (
        "# 更新日志 / Changelog`n`n## $Version - 2026-09-13`n`n### 中文`n`n- 测试夹具。SchemaVersion 2。`n`n### English`n`n- Test fixture. SchemaVersion 2.`n`n## 0.0.1 - 2020-01-01`n`n- Older entry.`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'README.md' -Text "# 测试说明`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'README.en.md' -Text "# Fixture readme`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'SKILL.md' -Text "# Fixture skill`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'LICENSE' -Text "Fixture license`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Invoke-360Cleanup.ps1' -PowerShellSource -Text (
        "#requires -Version 5.1`nSet-StrictMode -Version 2.0`n`$ErrorActionPreference = 'Stop'`n`$script:ToolVersion = '$Version'`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Windows360Cleaner.Library.ps1' -PowerShellSource -Text (
        "#requires -Version 5.1`nSet-StrictMode -Version 2.0`n`$ErrorActionPreference = 'Stop'`n`$script:W360ToolVersion = '$Version'`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Select-360Cleanup.ps1' -PowerShellSource -Text (
        "#requires -Version 5.1`n# Fixture selector: never executed by the packaging tests.`nSet-StrictMode -Version 2.0`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Show-360Summary.ps1' -PowerShellSource -Text (
        "#requires -Version 5.1`n# Fixture agent summary: never executed by the packaging tests.`nSet-StrictMode -Version 2.0`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/子目录 含空格/中文 脚本.ps1' -PowerShellSource -Text (
        "#requires -Version 5.1`n# 中文注释：用于检查 UTF-8 文件名和 BOM。`nSet-StrictMode -Version 2.0`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'tests/Test-Helpers.ps1' -PowerShellSource -Text (
        "#requires -Version 5.1`nSet-StrictMode -Version 2.0`n")
    Write-PackagingFixtureFile -Root $Root -RelativePath 'agents/openai.yaml' -Text "interface:`n  display_name: `"Fixture`"`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'references/guide.md' -Text "# Guide`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'assets/readme/diagram.svg' -Text '<svg xmlns="http://www.w3.org/2000/svg"></svg>'
    Write-PackagingFixtureFile -Root $Root -RelativePath 'assets/screenshots/screen.png' -Bytes ([byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF, 0x80, 0x7F))

    # Content that must never reach the package.
    Write-PackagingFixtureFile -Root $Root -RelativePath '.git/HEAD' -Text "ref: refs/heads/main`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath '.gitignore' -Text "dist/`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath '.gitattributes' -Text "*.ps1 text eol=crlf`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath '.github/workflows/validate.yml' -Text "name: fixture`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'docs/index.html' -Text '<html></html>'
    Write-PackagingFixtureFile -Root $Root -RelativePath 'dist/windows-360-cleaner-v0.0.1.zip' -Bytes ([byte[]](0x50, 0x4B, 0x05, 0x06))
    Write-PackagingFixtureFile -Root $Root -RelativePath 'tools/Build-Release.ps1' -PowerShellSource -Text "# fixture tool`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'packaging/notes.txt' -Text "packaging notes`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/360-cleanup-scan-20260913-101010-0a1b2c3d.json' -Text '{"SchemaVersion":2,"Mode":"Scan"}'
    Write-PackagingFixtureFile -Root $Root -RelativePath 'tests/reports/360-cleanup-verify-20260913-101010-0a1b2c3d.json' -Text '{"SchemaVersion":2,"Mode":"Verify"}'
    Write-PackagingFixtureFile -Root $Root -RelativePath 'references/360-cleanup-help-20260913-101010-0a1b2c3d.txt' -Text "help summary`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'tests/.gitkeep' -Text ''
    Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/debug.log' -Text "log`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'references/Thumbs.db' -Bytes ([byte[]](0x01, 0x02))
    Write-PackagingFixtureFile -Root $Root -RelativePath 'assets/other/unused.txt' -Text "not packaged`n"
    Write-PackagingFixtureFile -Root $Root -RelativePath 'notes-not-packaged.txt' -Text "not packaged`n"
    New-PackagingJunction -Path (Join-Path $Root 'references\linked-folder') -Target $OutsideDirectory

    return [pscustomobject]@{
        Root          = $Root
        Version       = $Version
        ExpectedFiles = @(
            '开始检查.cmd', 'Start-Check.cmd', '使用说明.txt', 'README.md', 'README.en.md', 'SKILL.md', 'LICENSE',
            'CHANGELOG.md', 'VERSION', 'agents/openai.yaml', 'references/guide.md', 'assets/readme/diagram.svg',
            'assets/screenshots/screen.png', 'scripts/Invoke-360Cleanup.ps1', 'scripts/Windows360Cleaner.Library.ps1',
            'scripts/Select-360Cleanup.ps1', 'scripts/Show-360Summary.ps1', 'scripts/Scan-360.cmd', 'scripts/Verify-360.cmd',
            'scripts/子目录 含空格/中文 脚本.ps1', 'tests/Test-Helpers.ps1'
        )
    }
}

function Get-PackagingTreeSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $rootInfo = New-Object System.IO.DirectoryInfo -ArgumentList $Root
    $prefixLength = $rootInfo.FullName.TrimEnd('\').Length
    $lines = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Stack
    $stack.Push($rootInfo)
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($child in @($directory.GetFileSystemInfos())) {
            $relativePath = $child.FullName.Substring($prefixLength)
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $lines.Add('L|' + $relativePath); continue }
            if ($child -is [IO.DirectoryInfo]) { $lines.Add('D|' + $relativePath); $stack.Push($child); continue }
            $hash = (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash
            $lines.Add(('F|{0}|{1}|{2}|{3}' -f $relativePath, $child.Length, $child.LastWriteTimeUtc.Ticks, $hash))
        }
    }
    $array = $lines.ToArray()
    [Array]::Sort($array, [StringComparer]::Ordinal)
    return ,$array
}

function Get-PackagingDirectoryFileNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) { return ,([string[]]@()) }
    $names = [string[]]@([IO.Directory]::GetFileSystemEntries($Path) | ForEach-Object { [IO.Path]::GetFileName($_) })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return ,$names
}

function Get-PackagingZipRawEntries {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    $bytes = [IO.File]::ReadAllBytes($ZipPath)
    $endRecord = -1
    $lowest = [Math]::Max(0, $bytes.Length - 22 - 65535)
    for ($index = $bytes.Length - 22; $index -ge $lowest; $index--) {
        if ($bytes[$index] -eq 0x50 -and $bytes[$index + 1] -eq 0x4B -and $bytes[$index + 2] -eq 0x05 -and $bytes[$index + 3] -eq 0x06) {
            $endRecord = $index
            break
        }
    }
    if ($endRecord -lt 0) { throw "The ZIP end-of-central-directory record was not found: $ZipPath" }

    $entryCount = [BitConverter]::ToUInt16($bytes, $endRecord + 10)
    $position = [int][BitConverter]::ToUInt32($bytes, $endRecord + 16)
    $strict = New-Object System.Text.UTF8Encoding($false, $true)
    $entries = New-Object System.Collections.ArrayList
    for ($entryIndex = 0; $entryIndex -lt $entryCount; $entryIndex++) {
        if ([BitConverter]::ToUInt32($bytes, $position) -ne [uint32]0x02014b50) {
            throw "Invalid central directory header at offset $position."
        }
        $flags = [int][BitConverter]::ToUInt16($bytes, $position + 8)
        $nameLength = [int][BitConverter]::ToUInt16($bytes, $position + 28)
        $extraLength = [int][BitConverter]::ToUInt16($bytes, $position + 30)
        $commentLength = [int][BitConverter]::ToUInt16($bytes, $position + 32)
        $localOffset = [int][BitConverter]::ToUInt32($bytes, $position + 42)
        $nameBytes = New-Object byte[] $nameLength
        [Array]::Copy($bytes, $position + 46, $nameBytes, 0, $nameLength)
        $hasNonAscii = $false
        foreach ($nameByte in $nameBytes) { if ($nameByte -ge 0x80) { $hasNonAscii = $true; break } }
        $name = $null
        try { $name = $strict.GetString($nameBytes) }
        catch { throw "A ZIP entry name is not valid UTF-8 (central directory offset $position)." }
        if ([BitConverter]::ToUInt32($bytes, $localOffset) -ne [uint32]0x04034b50) {
            throw "Invalid local file header for entry $name."
        }
        $localFlags = [int][BitConverter]::ToUInt16($bytes, $localOffset + 6)
        [void]$entries.Add([pscustomobject]@{
            Name          = $name
            HasNonAscii   = $hasNonAscii
            Utf8Flag      = (($flags -band 0x0800) -ne 0)
            LocalUtf8Flag = (($localFlags -band 0x0800) -ne 0)
        })
        $position += 46 + $nameLength + $extraLength + $commentLength
    }
    return $entries.ToArray()
}

function Read-PackagingZipEntries {
    param([Parameter(Mandatory = $true)][string]$ZipPath)

    $result = New-Object System.Collections.ArrayList
    $stream = New-Object System.IO.FileStream -ArgumentList $ZipPath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive -ArgumentList $stream, ([System.IO.Compression.ZipArchiveMode]::Read), $false
        try {
            foreach ($entry in $archive.Entries) {
                $isDirectory = $entry.FullName.EndsWith('/')
                $data = $null
                if (-not $isDirectory) {
                    $memory = New-Object System.IO.MemoryStream
                    try {
                        $entryStream = $entry.Open()
                        try { $entryStream.CopyTo($memory) }
                        finally { $entryStream.Dispose() }
                        $data = $memory.ToArray()
                    }
                    finally {
                        $memory.Dispose()
                    }
                }
                [void]$result.Add([pscustomobject]@{ Name = $entry.FullName; IsDirectory = $isDirectory; Bytes = $data })
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    return $result.ToArray()
}

function Assert-PackagingReleasePackage {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [string[]]$AdditionalRequiredFiles = @()
    )

    $packageRoot = 'windows-360-cleaner-v' + $Version
    $rootPrefix = $packageRoot + '/'
    Assert-TestEqual -Expected ($packageRoot + '.zip') -Actual ([IO.Path]::GetFileName($ZipPath)) -Message 'The ZIP file name must carry the version.'
    Assert-TestTrue ([IO.File]::Exists($ZipPath)) "The release ZIP was not created: $ZipPath"

    $rawEntries = @(Get-PackagingZipRawEntries -ZipPath $ZipPath)
    $entries = @(Read-PackagingZipEntries -ZipPath $ZipPath)
    Assert-TestTrue ($entries.Count -gt 0) 'The release ZIP is empty.'
    Assert-TestSequenceEqual -Expected @($rawEntries | ForEach-Object { $_.Name }) -Actual @($entries | ForEach-Object { $_.Name }) `
        -Message 'ZipArchive must decode exactly the UTF-8 names stored in the central directory.'

    foreach ($raw in $rawEntries) {
        Assert-TestFalse ($raw.Name.Contains('\')) ('ZIP entry names must use forward slashes: {0}' -f $raw.Name)
        Assert-TestTrue ($raw.Name.StartsWith($rootPrefix, [StringComparison]::Ordinal)) `
            ('Every ZIP entry must be inside the single root folder {0}: {1}' -f $rootPrefix, $raw.Name)
        Assert-TestFalse ([regex]::IsMatch($raw.Name, '(^|/)\.\.?(/|$)|//')) ('ZIP entry name has an unsafe segment: {0}' -f $raw.Name)
        if ($raw.HasNonAscii) {
            Assert-TestTrue ($raw.Utf8Flag -and $raw.LocalUtf8Flag) `
                ('A non-ASCII ZIP entry name must set the UTF-8 language encoding flag: {0}' -f $raw.Name)
        }
    }

    $files = @{}
    foreach ($entry in $entries) {
        $relativePath = $entry.Name.Substring($rootPrefix.Length)
        if ($relativePath.Length -eq 0) { continue }
        $segments = $relativePath.TrimEnd('/').Split('/')
        Assert-TestTrue ($script:AllowedPackageTopLevel -ccontains $segments[0]) ('Unexpected top-level package item: {0}' -f $entry.Name)
        if ($segments[0] -ceq 'assets' -and $segments.Count -gt 1) {
            Assert-TestTrue (@('readme', 'screenshots') -ccontains $segments[1]) ('Only assets/readme and assets/screenshots may be packaged: {0}' -f $entry.Name)
        }
        foreach ($segment in $segments) {
            Assert-TestFalse ($segment.StartsWith('.git', [StringComparison]::OrdinalIgnoreCase)) ('Git metadata must not be packaged: {0}' -f $entry.Name)
        }
        Assert-TestFalse (@('.github', 'docs', 'tools', 'packaging', 'dist') -contains $segments[0]) ('Excluded folder was packaged: {0}' -f $entry.Name)
        if ($entry.IsDirectory) { continue }
        Assert-TestFalse ([regex]::IsMatch($relativePath, '(^|/)360-cleanup-[^/]*\.json$', 'IgnoreCase')) ('A JSON report was packaged: {0}' -f $entry.Name)
        Assert-TestFalse ([regex]::IsMatch($relativePath, '(^|/)reports/', 'IgnoreCase')) ('A reports folder was packaged: {0}' -f $entry.Name)
        $files[$relativePath] = $entry.Bytes
    }

    foreach ($required in @($script:RequiredPackageFiles + $AdditionalRequiredFiles)) {
        Assert-TestTrue ($files.ContainsKey($required)) ('Required package file is missing: {0}{1}' -f $rootPrefix, $required)
    }
    foreach ($folder in $script:RequiredPackageFolders) {
        Assert-TestTrue (@($files.Keys | Where-Object { $_.StartsWith($folder, [StringComparison]::Ordinal) }).Count -gt 0) `
            ('Required package folder has no files: {0}{1}' -f $rootPrefix, $folder)
    }

    foreach ($relativePath in @($files.Keys)) {
        if ($relativePath -match '\.ps1$') {
            Assert-TestTrue (Test-PackagingUtf8Bom -Bytes $files[$relativePath]) ('A packaged .ps1 lost its UTF-8 BOM: {0}' -f $relativePath)
        }
        if ($relativePath -match '\.cmd$') {
            Assert-PackagingAsciiCrlf -Bytes $files[$relativePath] -Label ('Packaged {0}' -f $relativePath)
        }
    }

    $zhLauncher = $files['开始检查.cmd']
    $enLauncher = $files['Start-Check.cmd']
    Assert-TestEqual -Expected ([Convert]::ToBase64String($enLauncher)) -Actual ([Convert]::ToBase64String($zhLauncher)) `
        -Message 'Both packaged launchers must be identical.'
    $launcherText = [Text.Encoding]::ASCII.GetString($enLauncher)
    Assert-TestTrue ($launcherText.Contains('scripts\Select-360Cleanup.ps1') -and $launcherText.Contains('scripts\Invoke-360Cleanup.ps1')) `
        'The packaged launcher must reference both program scripts.'

    $guideBytes = $files['使用说明.txt']
    Assert-TestTrue (Test-PackagingUtf8Bom -Bytes $guideBytes) '使用说明.txt must be UTF-8 with BOM.'
    $guideText = ConvertFrom-PackagingUtf8 -Bytes $guideBytes
    Assert-PackagingCrlfText -Text $guideText -Label '使用说明.txt'
    Assert-TestTrue ($guideText.Contains('v' + $Version)) ('使用说明.txt does not show the rendered version v{0}.' -f $Version)
    Assert-TestFalse ($guideText.Contains('{{VERSION}}')) '使用说明.txt still contains the {{VERSION}} placeholder.'
    Assert-TestFalse ([regex]::IsMatch($guideText, '\{\{[A-Za-z0-9_]*\}\}')) '使用说明.txt still contains a template placeholder.'

    $packagedVersion = ConvertFrom-PackagingUtf8 -Bytes $files['VERSION']
    Assert-TestEqual -Expected $Version -Actual $packagedVersion.TrimEnd("`r", "`n") -Message 'The packaged VERSION file does not match.'

    $shaPath = $ZipPath + '.sha256'
    Assert-TestTrue ([IO.File]::Exists($shaPath)) "The .sha256 file was not created: $shaPath"
    $shaBytes = [IO.File]::ReadAllBytes($shaPath)
    foreach ($shaByte in $shaBytes) { Assert-TestTrue ($shaByte -lt 0x80) 'The .sha256 file must be ASCII-only.' }
    $shaText = [Text.Encoding]::ASCII.GetString($shaBytes)
    $shaMatch = [regex]::Match($shaText, '^([0-9a-fA-F]{64})  (\S+)\r?\n?\z')
    Assert-TestTrue $shaMatch.Success ('The .sha256 file must contain "<hash>  <file name>": {0}' -f $shaText)
    Assert-TestEqual -Expected ([IO.Path]::GetFileName($ZipPath)) -Actual $shaMatch.Groups[2].Value -Message 'The .sha256 file names the wrong ZIP.'
    Assert-TestEqual -Expected ((Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()) `
        -Actual $shaMatch.Groups[1].Value.ToLowerInvariant() -Message 'The .sha256 hash does not match the ZIP.'

    return [pscustomobject]@{ Entries = $entries; Files = $files }
}

function Get-PackagingVersionSources {
    $problems = New-Object System.Collections.ArrayList
    $values = [ordered]@{}

    $versionPath = Join-Path $script:RepositoryRoot 'VERSION'
    $version = $null
    if (-not [IO.File]::Exists($versionPath)) { [void]$problems.Add('VERSION: file not found.') }
    else {
        $versionText = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes($versionPath))
        $versionMatch = [regex]::Match($versionText, '^(\d+\.\d+\.\d+)\r?\n\z')
        if ($versionMatch.Success) { $version = $versionMatch.Groups[1].Value }
        else { [void]$problems.Add('VERSION: must contain exactly one version such as 1.0.0 plus a trailing newline.') }
    }
    $values['VERSION'] = $version
    $expected = $version
    if ($null -eq $expected) { $expected = '<VERSION>' }

    $constantSources = @(
        [pscustomobject]@{ Label = 'core scripts/Invoke-360Cleanup.ps1'; Path = $script:CoreScriptPath; Variable = 'ToolVersion' }
        [pscustomobject]@{ Label = 'library scripts/Windows360Cleaner.Library.ps1'; Path = $script:LibraryScriptPath; Variable = 'W360ToolVersion' }
    )
    foreach ($source in $constantSources) {
        $expectedLine = ('$script:{0} = ''{1}''' -f $source.Variable, $expected)
        $values[$source.Label] = $null
        if (-not [IO.File]::Exists($source.Path)) {
            [void]$problems.Add(('{0}: file not found ({1}); it must contain the exact line {2}' -f $source.Label, $source.Path, $expectedLine))
            continue
        }
        $text = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes($source.Path))
        $pattern = '(?m)^\$script:' + [regex]::Escape($source.Variable) + " = '([^'\r\n]*)'\r?$"
        $lineMatches = [regex]::Matches($text, $pattern)
        if ($lineMatches.Count -eq 0) {
            [void]$problems.Add(('{0}: version constant line not found; expected the exact line {1} (the constant does not exist yet or is formatted differently).' -f $source.Label, $expectedLine))
            continue
        }
        if ($lineMatches.Count -gt 1) {
            [void]$problems.Add(('{0}: the version constant line appears {1} times; exactly one is required.' -f $source.Label, $lineMatches.Count))
            continue
        }
        $values[$source.Label] = $lineMatches[0].Groups[1].Value
        if ($null -ne $version -and $lineMatches[0].Groups[1].Value -cne $version) {
            [void]$problems.Add(('{0}: constant is ''{1}'' but VERSION is ''{2}''.' -f $source.Label, $lineMatches[0].Groups[1].Value, $version))
        }
    }

    $changelogPath = Join-Path $script:RepositoryRoot 'CHANGELOG.md'
    $values['CHANGELOG.md'] = $null
    if (-not [IO.File]::Exists($changelogPath)) { [void]$problems.Add('CHANGELOG.md: file not found.') }
    else {
        $changelogText = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes($changelogPath))
        $heading = [regex]::Match($changelogText, '(?m)^## (?!#)(.*?)\r?$')
        $headingMatch = $null
        if ($heading.Success) { $headingMatch = [regex]::Match($heading.Groups[1].Value, '^(\d+\.\d+\.\d+) - (\d{4}-\d{2}-\d{2})$') }
        if ($null -eq $headingMatch -or -not $headingMatch.Success) {
            [void]$problems.Add(('CHANGELOG.md: the top heading must be "## {0} - yyyy-MM-dd".' -f $expected))
        }
        else {
            $values['CHANGELOG.md'] = $headingMatch.Groups[1].Value
            if ($null -ne $version -and $headingMatch.Groups[1].Value -cne $version) {
                [void]$problems.Add(('CHANGELOG.md: top heading is {0} but VERSION is {1}.' -f $headingMatch.Groups[1].Value, $version))
            }
        }
    }

    return [pscustomobject]@{ Version = $version; Values = $values; Problems = @($problems) }
}

function Stop-PackagingProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    $children = @(Get-CimInstance -ClassName Win32_Process -Filter ('ParentProcessId = {0}' -f $ProcessId) -ErrorAction SilentlyContinue)
    foreach ($child in $children) { Stop-PackagingProcessTree -ProcessId ([int]$child.ProcessId) }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Invoke-PackagingLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 90
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = Join-Path ([Environment]::SystemDirectory) 'cmd.exe'
    $startInfo.Arguments = '/d /s /c ""' + $LauncherPath + '""'
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    # CreateNoWindow gives the launcher its own hidden console, so -WindowStyle Hidden can never hide the test console.
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables[$script:LauncherTestVariable] = '1'

    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            Stop-PackagingProcessTree -ProcessId $process.Id
            throw ('The launcher did not exit within {0} seconds: {1}' -f $TimeoutSeconds, $LauncherPath)
        }
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout   = $stdoutTask.Result
            Stderr   = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-PackagingDummySelector {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptsDirectory,
        [int]$ExitCode = 7
    )

    Write-PackagingFixtureFile -Root $ScriptsDirectory -RelativePath 'Select-360Cleanup.ps1' -PowerShellSource -Text (
        "# Dummy selector written by tests/Test-Packaging.ps1. It is not the real GUI.`n" +
        "`$pathBytes = [Text.Encoding]::UTF8.GetBytes([string]`$PSCommandPath)`n" +
        "[Console]::Out.WriteLine('" + $script:DummySelectorMarker + "' + [Convert]::ToBase64String(`$pathBytes) + '|' + `$args.Count)`n" +
        "exit $ExitCode`n")
}

function Invoke-PackagingBuild {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [switch]$Force
    )

    $arguments = @{
        RepositoryRoot  = $RepositoryRoot
        OutputDirectory = $OutputDirectory
        WarningAction   = 'SilentlyContinue'
    }
    if ($Force) { $arguments['Force'] = $true }
    return (& $script:BuildScriptPath @arguments 6>$null)
}

$run = New-TestRun -Name 'Packaging tests'
$testRoot = $null

try {
    $testRoot = New-TestDirectory

    Invoke-TestCase -Run $run -Name 'packaging PowerShell files follow the Windows PowerShell 5.1 source contract' -Test {
        Assert-TestTrue ([IO.File]::Exists($script:BuildScriptPath)) ('tools/Build-Release.ps1 is missing. Test-Packaging.ps1 must run from a source checkout: {0}' -f $script:BuildScriptPath)
        foreach ($path in @($helpersPath, $packagingTestPath, $script:BuildScriptPath)) {
            Assert-TestPowerShellFileContract -Path $path
        }
        foreach ($path in @($packagingTestPath, $script:BuildScriptPath)) {
            $text = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes($path))
            Assert-TestTrue ($text.StartsWith('#requires -Version 5.1')) "Missing #requires -Version 5.1: $path"
            Assert-TestTrue ($text.Contains('Set-StrictMode -Version 2.0')) "Missing Set-StrictMode -Version 2.0: $path"
            Assert-TestTrue ($text.Contains('$ErrorActionPreference = ''Stop''')) "Missing `$ErrorActionPreference = 'Stop': $path"
        }
        $buildText = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes($script:BuildScriptPath))
        foreach ($forbidden in @('Invoke-WebRequest', 'Invoke-RestMethod', 'Net.WebClient', 'HttpClient', 'gh release', 'git push', 'git tag', 'git commit', 'Remove-Item', 'Start-Process', 'Invoke-360Cleanup.ps1 -Mode')) {
            Assert-TestFalse ($buildText.Contains($forbidden)) ('Build-Release.ps1 must not publish, upload or run cleanup commands ({0}).' -f $forbidden)
        }
        Assert-TestTrue ($buildText.Contains('System.IO.Compression.ZipArchive')) 'Build-Release.ps1 must use System.IO.Compression.ZipArchive directly.'
    }

    Invoke-TestCase -Run $run -Name 'root launchers are identical ASCII CRLF files that check the program files and only open the selector' -Test {
        $launcherBytes = @{}
        foreach ($name in $script:LauncherNames) {
            $path = Join-Path $script:RepositoryRoot $name
            Assert-TestTrue ([IO.File]::Exists($path)) "Root launcher is missing: $path"
            $launcherBytes[$name] = [IO.File]::ReadAllBytes($path)
            Assert-PackagingAsciiCrlf -Bytes $launcherBytes[$name] -Label $name
        }
        Assert-TestEqual -Expected ([Convert]::ToBase64String($launcherBytes['Start-Check.cmd'])) `
            -Actual ([Convert]::ToBase64String($launcherBytes['开始检查.cmd'])) -Message 'The two root launchers must have identical content.'

        $text = [Text.Encoding]::ASCII.GetString($launcherBytes['Start-Check.cmd'])
        $lines = @($text -split "`r`n")
        Assert-TestTrue ($lines -ccontains 'if not exist "%~dp0scripts\Select-360Cleanup.ps1" goto missing') 'The launcher must check scripts\Select-360Cleanup.ps1.'
        Assert-TestTrue ($lines -ccontains 'if not exist "%~dp0scripts\Invoke-360Cleanup.ps1" goto missing') 'The launcher must check scripts\Invoke-360Cleanup.ps1.'
        Assert-TestTrue ($lines -ccontains $script:NormalLauncherCommand) ('The launcher must run exactly: {0}' -f $script:NormalLauncherCommand)

        $powerShellLines = @($lines | Where-Object { $_ -match '^\s*powershell(\.exe)?\s' })
        Assert-TestEqual -Expected 3 -Actual $powerShellLines.Count -Message 'The launcher must start PowerShell only for the selector, the missing-files message, and the could-not-run message.'
        Assert-TestTrue ($powerShellLines[2].StartsWith('powershell.exe -NoProfile -EncodedCommand ', [StringComparison]::Ordinal)) `
            'The third PowerShell command must be the encoded could-not-run message.'
        $failedScript = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($powerShellLines[2].Substring('powershell.exe -NoProfile -EncodedCommand '.Length)))
        Assert-TestTrue ($failedScript.Contains('[System.Windows.Forms.MessageBox]::Show(') -and $failedScript.Contains('Scan-360.cmd')) `
            'The could-not-run message must be a MessageBox that points to Scan-360.cmd.'
        foreach ($forbidden in @('Invoke-360Cleanup', 'Select-360Cleanup', 'Remove-Item', 'Start-Process', 'Invoke-Expression')) {
            Assert-TestFalse ($failedScript.Contains($forbidden)) ('The could-not-run message command must only show a message ({0}).' -f $forbidden)
        }
        foreach ($expected in @($script:FailedChineseTexts) + @($script:FailedEnglishTexts)) {
            Assert-TestTrue ($failedScript.Contains($expected)) ('The could-not-run message must say: {0}' -f $expected)
        }
        $failedTokens = $null
        $failedErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($failedScript, [ref]$failedTokens, [ref]$failedErrors)
        Assert-TestEqual -Expected 0 -Actual $failedErrors.Count -Message 'The encoded could-not-run command must parse without errors.'
        foreach ($oldWord in $script:LauncherOldWords) {
            Assert-TestFalse ($failedScript.IndexOf($oldWord, [StringComparison]::OrdinalIgnoreCase) -ge 0) ('The could-not-run message still uses the old wording: {0}' -f $oldWord)
        }
        Assert-TestEqual -Expected $script:NormalLauncherCommand -Actual $powerShellLines[0] -Message 'The first PowerShell command must open the selector.'
        Assert-TestTrue ($powerShellLines[1].StartsWith('powershell.exe -NoProfile -EncodedCommand ', [StringComparison]::Ordinal)) `
            'The second PowerShell command must be the encoded missing-files message.'
        foreach ($forbidden in @('-Mode', '-ConfirmRemoval', 'REMOVE-CONFIRMED-360', '-ApprovedReport', '-SelectedFindingIds', 'Remove-360.cmd')) {
            Assert-TestFalse ($text.Contains($forbidden)) ('The beginner launcher must never start a removal ({0}).' -f $forbidden)
        }

        $normalIndex = [Array]::IndexOf($lines, $script:NormalLauncherCommand)
        $missingIndex = [Array]::IndexOf($lines, ':missing')
        $hookIndex = [Array]::IndexOf($lines, ('if defined {0} goto missing_test' -f $script:LauncherTestVariable))
        $encodedIndex = [Array]::IndexOf($lines, $powerShellLines[1])
        $checkIndexes = @(for ($index = 0; $index -lt $lines.Count; $index++) { if ($lines[$index] -match '^if not exist ') { $index } })
        Assert-TestTrue ($checkIndexes.Count -ge 2 -and ($checkIndexes | Measure-Object -Maximum).Maximum -lt $normalIndex) 'The program-file checks must run before the selector starts.'
        Assert-TestTrue ($normalIndex -lt $missingIndex -and $lines[$normalIndex + 1] -ceq 'set "W360_RESULT=%ERRORLEVEL%"' -and
            $lines[$normalIndex + 2] -ceq 'if "%W360_RESULT%"=="0" exit /b 0') 'The selector exit code must be captured and a clean exit returned before the :missing label.'
        Assert-TestTrue ($lines -ccontains 'if "%W360_RESULT%"=="20" exit /b 20') 'Exit code 20 (the window showed its own error) must not show a second message.'
        Assert-TestTrue ($missingIndex -lt $hookIndex -and $hookIndex -lt $encodedIndex) 'The test hook must be checked before the message box is shown.'
        Assert-TestEqual -Expected 'exit /b 1' -Actual $lines[$encodedIndex + 1] -Message 'The missing-files path must exit with code 1.'
        $hookDocumentation = @($lines[0..($hookIndex - 1)] | Where-Object { $_ -match '^REM ' -and $_.Contains($script:LauncherTestVariable) })
        Assert-TestTrue ($hookDocumentation.Count -ge 1) 'The launcher test hook must be documented with a REM line.'
        Assert-TestTrue ($lines -ccontains ('echo ' + $script:LauncherTestMarker)) 'The launcher test hook must print the documented marker.'
    }

    Invoke-TestCase -Run $run -Name 'launcher missing-files message is a valid Chinese and English MessageBox command' -Test {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot 'Start-Check.cmd'), [Text.Encoding]::ASCII)
        $encodedMatch = [regex]::Match($text, '(?m)^powershell\.exe -NoProfile -EncodedCommand ([A-Za-z0-9+/=]+)\r?$')
        Assert-TestTrue $encodedMatch.Success 'The launcher must show the missing-files message through powershell.exe -NoProfile -EncodedCommand.'
        $encodedBytes = [Convert]::FromBase64String($encodedMatch.Groups[1].Value)
        Assert-TestEqual -Expected 0 -Actual ($encodedBytes.Length % 2) -Message 'The encoded command must be UTF-16LE.'
        $decodedScript = [Text.Encoding]::Unicode.GetString($encodedBytes)
        Assert-TestEqual -Expected ([Convert]::ToBase64String($encodedBytes)) -Actual ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($decodedScript))) `
            -Message 'The encoded command does not round-trip as UTF-16LE.'
        Assert-TestTrue ($decodedScript.Contains('[System.Windows.Forms.MessageBox]::Show(')) 'The encoded command must call [System.Windows.Forms.MessageBox]::Show.'
        Assert-TestTrue ($decodedScript.Contains($script:MissingFilesChineseText)) 'The encoded command must contain the Chinese missing-files text from the SPEC.'
        Assert-TestTrue ($decodedScript.Contains('Extract All') -and $decodedScript.Contains('Start-Check') -and $decodedScript.Contains('scripts folder')) 'The encoded command must contain the English explanation.'
        foreach ($oldWord in $script:LauncherOldWords) {
            Assert-TestFalse ($decodedScript.IndexOf($oldWord, [StringComparison]::OrdinalIgnoreCase) -ge 0) ('The missing-files message still uses the old wording: {0}' -f $oldWord)
        }
        foreach ($forbidden in @('Invoke-360Cleanup', 'Select-360Cleanup', 'Remove-Item', 'Start-Process', 'Invoke-Expression', 'DownloadString', 'Invoke-WebRequest')) {
            Assert-TestFalse ($decodedScript.Contains($forbidden)) ('The encoded message command must only show a message ({0}).' -f $forbidden)
        }
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($decodedScript, [ref]$tokens, [ref]$parseErrors)
        Assert-TestEqual -Expected 0 -Actual $parseErrors.Count -Message 'The encoded message command must parse without errors.'
    }

    Invoke-TestCase -Run $run -Name 'launcher copied alone into an empty folder exits 1 through the documented test hook' -Test {
        $index = 0
        foreach ($name in $script:LauncherNames) {
            $index++
            $folder = Join-Path $testRoot ('launcher-alone-{0}\解压 后 (测试) & more' -f $index)
            [void][IO.Directory]::CreateDirectory($folder)
            $copy = Join-Path $folder $name
            [IO.File]::WriteAllBytes($copy, [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot $name)))

            $result = Invoke-PackagingLauncher -LauncherPath $copy -WorkingDirectory $testRoot
            Assert-TestEqual -Expected 1 -Actual $result.ExitCode -Message ('{0} copied alone must exit 1. Output: {1} {2}' -f $name, $result.Stdout, $result.Stderr)
            Assert-TestTrue ($result.Stdout.Contains($script:LauncherTestMarker)) ('{0} did not take the missing-files path. Output: {1} {2}' -f $name, $result.Stdout, $result.Stderr)
            Assert-TestFalse ($result.Stdout.Contains($script:DummySelectorMarker)) "$name must not start any selector."
            Assert-TestSequenceEqual -Expected @($name) -Actual (Get-PackagingDirectoryFileNames -Path $folder) -Message "$name must not create files next to itself."
        }
    }

    Invoke-TestCase -Run $run -Name 'launcher with only some program files present still exits 1 before starting anything' -Test {
        $layouts = @(
            @{ Name = 'selector-only'; Files = @('Select-360Cleanup.ps1', 'Windows360Cleaner.Library.ps1') }
            @{ Name = 'core-only'; Files = @('Invoke-360Cleanup.ps1', 'Windows360Cleaner.Library.ps1') }
            @{ Name = 'no-library'; Files = @('Select-360Cleanup.ps1', 'Invoke-360Cleanup.ps1') }
        )
        foreach ($layout in $layouts) {
            $folder = Join-Path $testRoot ('launcher-partial-{0}\解压 后' -f $layout.Name)
            $scriptsFolder = Join-Path $folder 'scripts'
            [void][IO.Directory]::CreateDirectory($scriptsFolder)
            $launcher = Join-Path $folder 'Start-Check.cmd'
            [IO.File]::WriteAllBytes($launcher, [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'Start-Check.cmd')))
            foreach ($file in $layout.Files) {
                if ($file -eq 'Select-360Cleanup.ps1') { New-PackagingDummySelector -ScriptsDirectory $scriptsFolder }
                else { Write-PackagingFixtureFile -Root $scriptsFolder -RelativePath $file -PowerShellSource -Text "# dummy`n" }
            }

            $result = Invoke-PackagingLauncher -LauncherPath $launcher -WorkingDirectory $testRoot
            Assert-TestEqual -Expected 1 -Actual $result.ExitCode -Message ('Layout {0} must exit 1. Output: {1} {2}' -f $layout.Name, $result.Stdout, $result.Stderr)
            Assert-TestTrue ($result.Stdout.Contains($script:LauncherTestMarker)) ('Layout {0} did not take the missing-files path.' -f $layout.Name)
            Assert-TestFalse ($result.Stdout.Contains($script:DummySelectorMarker)) ('Layout {0} must not start the selector.' -f $layout.Name)
        }
    }

    Invoke-TestCase -Run $run -Name 'launcher with the program files present runs its own scripts\Select-360Cleanup.ps1 (dummy) and returns its exit code' -Test {
        $folder = Join-Path $testRoot 'launcher-normal\解压 后 (测试)'
        $scriptsFolder = Join-Path $folder 'scripts'
        [void][IO.Directory]::CreateDirectory($scriptsFolder)
        $launcher = Join-Path $folder '开始检查.cmd'
        [IO.File]::WriteAllBytes($launcher, [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot '开始检查.cmd')))
        New-PackagingDummySelector -ScriptsDirectory $scriptsFolder
        Write-PackagingFixtureFile -Root $scriptsFolder -RelativePath 'Invoke-360Cleanup.ps1' -PowerShellSource -Text "throw 'The dummy core must never run.'`n"
        Write-PackagingFixtureFile -Root $scriptsFolder -RelativePath 'Windows360Cleaner.Library.ps1' -PowerShellSource -Text "throw 'The dummy library must never run.'`n"

        $result = Invoke-PackagingLauncher -LauncherPath $launcher -WorkingDirectory $testRoot
        Assert-TestEqual -Expected 7 -Actual $result.ExitCode -Message ('The launcher must return the selector exit code. Output: {0} {1}' -f $result.Stdout, $result.Stderr)
        Assert-TestFalse ($result.Stdout.Contains($script:LauncherTestMarker)) 'The launcher took the missing-files path although the program files exist.'
        Assert-TestTrue ($result.Stdout.Contains('W360-LAUNCHER-TEST: SelectorFailed 7')) 'An unexpected selector exit code must take the could-not-run message path.'
        foreach ($handledCode in @(0, 20)) {
            $handledFolder = Join-Path $testRoot ('launcher-handled-{0}\解压 后' -f $handledCode)
            $handledScripts = Join-Path $handledFolder 'scripts'
            [void][IO.Directory]::CreateDirectory($handledScripts)
            $handledLauncher = Join-Path $handledFolder 'Start-Check.cmd'
            [IO.File]::WriteAllBytes($handledLauncher, [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'Start-Check.cmd')))
            New-PackagingDummySelector -ScriptsDirectory $handledScripts -ExitCode $handledCode
            Write-PackagingFixtureFile -Root $handledScripts -RelativePath 'Invoke-360Cleanup.ps1' -PowerShellSource -Text "throw 'The dummy core must never run.'`n"
            Write-PackagingFixtureFile -Root $handledScripts -RelativePath 'Windows360Cleaner.Library.ps1' -PowerShellSource -Text "throw 'The dummy library must never run.'`n"
            $handled = Invoke-PackagingLauncher -LauncherPath $handledLauncher -WorkingDirectory $testRoot
            Assert-TestEqual -Expected $handledCode -Actual $handled.ExitCode -Message "The launcher changed the handled exit code $handledCode."
            Assert-TestFalse ($handled.Stdout.Contains('W360-LAUNCHER-TEST: SelectorFailed')) "Exit code $handledCode must not show the could-not-run message."
        }
        $markerMatch = [regex]::Match($result.Stdout, [regex]::Escape($script:DummySelectorMarker) + '([A-Za-z0-9+/=]+)\|(\d+)')
        Assert-TestTrue $markerMatch.Success ('The dummy selector did not run. Output: {0} {1}' -f $result.Stdout, $result.Stderr)
        $selectorPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($markerMatch.Groups[1].Value))
        $expectedSuffix = '\launcher-normal\解压 后 (测试)\scripts\Select-360Cleanup.ps1'
        Assert-TestTrue ($selectorPath.EndsWith($expectedSuffix, [StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($selectorPath)) `
            ('The launcher must run the selector next to itself. Actual: {0}' -f $selectorPath)
        Assert-TestEqual -Expected '0' -Actual $markerMatch.Groups[2].Value -Message 'The launcher must not pass extra arguments to the selector.'
    }

    Invoke-TestCase -Run $run -Name 'Scan-360.cmd and Verify-360.cmd open the selector on read-only start pages' -Test {
        $expectations = @(
            @{ Name = 'Scan-360.cmd'; Command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-360Cleanup.ps1" -StartPage Scan' }
            @{ Name = 'Verify-360.cmd'; Command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Select-360Cleanup.ps1" -StartPage Verify' }
        )
        foreach ($expectation in $expectations) {
            $path = Join-Path $script:RepositoryRoot ('scripts\' + $expectation.Name)
            $bytes = [IO.File]::ReadAllBytes($path)
            Assert-PackagingAsciiCrlf -Bytes $bytes -Label $expectation.Name
            $text = [Text.Encoding]::ASCII.GetString($bytes)
            $lines = @($text -split "`r`n")
            Assert-TestTrue ($lines -ccontains $expectation.Command) ('{0} must run exactly: {1}' -f $expectation.Name, $expectation.Command)
            Assert-TestTrue ($text.Contains('Select-360Cleanup.ps1')) ('{0} must open the selector.' -f $expectation.Name)
            Assert-TestFalse ($text.Contains('Invoke-360Cleanup.ps1')) ('{0} must not bypass the selector.' -f $expectation.Name)
            Assert-TestFalse ($text.Contains('-Mode')) ('{0} must not pass a cleanup mode.' -f $expectation.Name)
            Assert-TestTrue ($lines -ccontains 'pause') ('{0} must keep the visible console pause.' -f $expectation.Name)
            Assert-TestFalse ($text.Contains('-WindowStyle Hidden')) ('{0} must keep its console visible.' -f $expectation.Name)
        }
    }

    Invoke-TestCase -Run $run -Name 'VERSION contains exactly one semantic version and a trailing newline' -Test {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'VERSION'))
        Assert-TestFalse (Test-PackagingUtf8Bom -Bytes $bytes) 'VERSION must not start with a BOM.'
        $text = [Text.Encoding]::ASCII.GetString($bytes)
        Assert-TestTrue ([regex]::IsMatch($text, '^\d+\.\d+\.\d+\r?\n\z')) ('VERSION must contain exactly one version plus a trailing newline. Actual: {0}' -f $text.Replace("`r", '\r').Replace("`n", '\n'))
    }

    Invoke-TestCase -Run $run -Name 'CHANGELOG lists the newest release first with Chinese before English and keeps SchemaVersion 2' -Test {
        $text = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes((Join-Path $script:RepositoryRoot 'CHANGELOG.md')))
        $headings = [regex]::Matches($text, '(?m)^## (?!#)(.*?)\r?$')
        Assert-TestTrue ($headings.Count -ge 1) 'CHANGELOG.md has no release heading.'
        Assert-TestTrue ([regex]::IsMatch($headings[0].Groups[1].Value, '^\d+\.\d+\.\d+ - \d{4}-\d{2}-\d{2}$')) ('The top CHANGELOG heading must be "## <version> - yyyy-MM-dd": {0}' -f $headings[0].Value)
        $sectionEnd = $text.Length
        if ($headings.Count -gt 1) { $sectionEnd = $headings[1].Index }
        $section = $text.Substring($headings[0].Index, $sectionEnd - $headings[0].Index)
        $chineseIndex = $section.IndexOf('### 中文', [StringComparison]::Ordinal)
        $englishIndex = $section.IndexOf('### English', [StringComparison]::Ordinal)
        Assert-TestTrue ($chineseIndex -ge 0 -and $englishIndex -gt $chineseIndex) 'The newest CHANGELOG section must have a Chinese part before the English part.'
        Assert-TestTrue ($section.Substring($chineseIndex, $englishIndex - $chineseIndex).Contains('SchemaVersion 2')) 'The Chinese CHANGELOG part must state that reports stay SchemaVersion 2.'
        Assert-TestTrue ($section.Substring($englishIndex).Contains('SchemaVersion 2')) 'The English CHANGELOG part must state that reports stay SchemaVersion 2.'
        foreach ($phrase in @('开始检查', '求助摘要', '部分清理后的复检区分', '扫描覆盖完整性', '进度与取消', '中文分组清单', '重启复检', '没有版本号', '打包', 'Selection', 'TaskVerification', 'ScanCoverage', 'ProductKey', 'ToolVersion')) {
            Assert-TestTrue ($section.Contains($phrase)) ('The newest CHANGELOG section does not mention: {0}' -f $phrase)
        }
    }

    Invoke-TestCase -Run $run -Name '使用说明 template is UTF-8 with BOM and CRLF with the version placeholder and beginner guidance' -Test {
        $bytes = [IO.File]::ReadAllBytes($script:TemplatePath)
        Assert-TestTrue (Test-PackagingUtf8Bom -Bytes $bytes) 'packaging/使用说明.txt must be UTF-8 with BOM.'
        $text = ConvertFrom-PackagingUtf8 -Bytes $bytes
        Assert-PackagingCrlfText -Text $text -Label 'packaging/使用说明.txt'
        Assert-TestTrue ($text.Contains('v{{VERSION}}')) 'The template must contain the v{{VERSION}} placeholder.'
        Assert-TestEqual -Expected 0 -Actual ([regex]::Matches($text, '\{\{(?!VERSION\}\})[A-Za-z0-9_]*\}\}').Count) -Message 'The template may only use the {{VERSION}} placeholder.'
        # The manual names the buttons the window really has.
        foreach ($phrase in @('Windows 10', 'PowerShell 5.1', '全部解压', '双击“开始检查”', '自己决定删不删', '确定要删除吗？', '手动重启', '检查上次删除的结果',
                '一个都不勾选', '不是建议删除', '书签', '永久', '不会自动重启', '不会上传', '获取帮助', '删除选中的内容…', '全选可以删除的', '“删除”',
                '打开记录所在文件夹', '重新检查电脑', '停止检查', '桌面', '360-cleanup-', 'https://github.com/LongXL6/windows-360-cleaner', 'English',
                'Check the last deletion', 'Get help', 'Delete selected...',
                # A deletion made in a conversation never appears on the home page; an older window deletion may.
                '更早一次在窗口里的删除', '请看上面的时间', 'check its time',
                # The agent route comes first: the skill, what to say, and that a suggestion is not approval.
                'AI Agent', 'SKILL.md', '建议删除', '确定删除', '重启好了', 'yes, delete')) {
            Assert-TestTrue ($text.Contains($phrase)) ('The template does not mention: {0}' -f $phrase)
        }
        # Buttons and words the window no longer shows must not send beginners looking for them.
        foreach ($oldName in @('只保留报告并关闭', '清理所选项目', '确认删除并请求管理员授权', '复检上次清理', '生成求助摘要', '打开报告所在文件夹',
                '管理员授权', '已识别', '厂商卸载程序', 'Verify last cleanup', 'Create help summary')) {
            Assert-TestFalse ($text.Contains($oldName)) ('The template still names something the window no longer shows: {0}' -f $oldName)
        }
        Assert-TestTrue ($text.IndexOf('English', [StringComparison]::Ordinal) -gt $text.IndexOf('获取帮助', [StringComparison]::Ordinal)) 'The English section must come after the Chinese guidance.'
    }

    Invoke-TestCase -Run $run -Name '.gitignore ignores the dist/ build output' -Test {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepositoryRoot '.gitignore'), [Text.Encoding]::ASCII)
        Assert-TestTrue ([regex]::IsMatch($text, '(?m)^dist/\r?$')) '.gitignore must contain a dist/ line.'
    }

    Invoke-TestCase -Run $run -Name 'version consistency: VERSION, core constant, library constant and CHANGELOG agree, and the real repository builds a valid package' -Test {
        $sources = Get-PackagingVersionSources
        if ($sources.Problems.Count -gt 0) {
            $found = @($sources.Values.Keys | ForEach-Object {
                $value = $sources.Values[$_]
                if ($null -eq $value) { $value = '<missing>' }
                '{0}={1}' -f $_, $value
            }) -join '; '
            throw ("Version sources are missing or disagree ({0}):{1}{2}" -f $found, [Environment]::NewLine,
                (@($sources.Problems | ForEach-Object { ' - ' + $_ }) -join [Environment]::NewLine))
        }

        $output = Join-Path $testRoot 'real-repository-output'
        $result = Invoke-PackagingBuild -RepositoryRoot $script:RepositoryRoot -OutputDirectory $output
        Assert-TestEqual -Expected $sources.Version -Actual $result.Version -Message 'The build used a different version.'
        [void](Assert-PackagingReleasePackage -ZipPath $result.ZipPath -Version $sources.Version -AdditionalRequiredFiles @(
            'scripts/Scan-360.cmd', 'scripts/Verify-360.cmd', 'tests/Test-Helpers.ps1', 'tests/Test-Packaging.ps1', 'tests/Test-AgentSummary.ps1', 'agents/openai.yaml'))
        $zipName = [IO.Path]::GetFileName($result.ZipPath)
        Assert-TestSequenceEqual -Expected @($zipName, ($zipName + '.sha256')) -Actual (Get-PackagingDirectoryFileNames -Path $output) `
            -Message 'The real build must write only the ZIP and its .sha256 file.'
    }

    Invoke-TestCase -Run $run -Name 'fixture build packages exactly the included files with UTF-8 names, one versioned root folder and a matching sha256' -Test {
        $fixture = New-PackagingFixture -Root (Join-Path $testRoot 'fixture-main\源 代码 (repo)') -Version '9.8.7' `
            -OutsideDirectory (Join-Path $testRoot 'fixture-main\outside')
        $sourceBefore = Get-PackagingTreeSnapshot -Root $fixture.Root
        $outsideBefore = Get-PackagingTreeSnapshot -Root (Join-Path $testRoot 'fixture-main\outside')
        $output = Join-Path $testRoot 'fixture-main\输出 output'

        $result = Invoke-PackagingBuild -RepositoryRoot $fixture.Root -OutputDirectory $output
        Assert-TestEqual -Expected (Join-Path $output 'windows-360-cleaner-v9.8.7.zip') -Actual $result.ZipPath -Message 'Unexpected ZIP path.'
        $package = Assert-PackagingReleasePackage -ZipPath $result.ZipPath -Version '9.8.7'

        $expected = [string[]]@($fixture.ExpectedFiles)
        [Array]::Sort($expected, [StringComparer]::Ordinal)
        $actual = [string[]]@($package.Files.Keys)
        [Array]::Sort($actual, [StringComparer]::Ordinal)
        Assert-TestSequenceEqual -Expected $expected -Actual $actual -Message 'The fixture package must contain exactly the included files.'
        Assert-TestTrue (@($package.Entries | Where-Object { $_.Name -ceq 'windows-360-cleaner-v9.8.7/' }).Count -eq 1) 'The ZIP must contain the root folder entry.'
        $fileEntryNames = [string[]]@($package.Entries | Where-Object { -not $_.IsDirectory } | ForEach-Object { $_.Name })
        $sortedFileEntryNames = [string[]]$fileEntryNames.Clone()
        [Array]::Sort($sortedFileEntryNames, [StringComparer]::Ordinal)
        Assert-TestSequenceEqual -Expected $sortedFileEntryNames -Actual $fileEntryNames -Message 'File entries must be written in a deterministic ordinal order.'

        foreach ($relativePath in $expected) {
            if ($relativePath -ceq '使用说明.txt') { continue }
            $sourceBytes = [IO.File]::ReadAllBytes((Join-Path $fixture.Root ($relativePath.Replace('/', '\'))))
            Assert-TestEqual -Expected ([Convert]::ToBase64String($sourceBytes)) -Actual ([Convert]::ToBase64String($package.Files[$relativePath])) `
                -Message ('Packaged bytes differ from the working tree: {0}' -f $relativePath)
        }
        $template = ConvertFrom-PackagingUtf8 -Bytes ([IO.File]::ReadAllBytes((Join-Path $fixture.Root 'packaging\使用说明.txt')))
        $rendered = ConvertFrom-PackagingUtf8 -Bytes $package.Files['使用说明.txt']
        Assert-TestEqual -Expected ([regex]::Replace($template.Replace('{{VERSION}}', '9.8.7'), "\r\n|\r|\n", "`r`n")) -Actual $rendered `
            -Message '使用说明.txt must be the template rendered with the version.'

        Assert-TestTrue (@($result.SkippedReparsePoints) -ccontains 'references/linked-folder') 'The junction must be reported as skipped.'
        Assert-TestFalse (@($package.Files.Keys | Where-Object { $_.Contains('outside-secret') -or $_.Contains('linked-folder') }).Count -gt 0) 'Content behind a junction was packaged.'
        Assert-TestSequenceEqual -Expected @('windows-360-cleaner-v9.8.7.zip', 'windows-360-cleaner-v9.8.7.zip.sha256') `
            -Actual (Get-PackagingDirectoryFileNames -Path $output) -Message 'The build must write only the ZIP and its .sha256 file.'
        Assert-TestSequenceEqual -Expected $sourceBefore -Actual (Get-PackagingTreeSnapshot -Root $fixture.Root) -Message 'The build modified the source tree.'
        Assert-TestSequenceEqual -Expected $outsideBefore -Actual (Get-PackagingTreeSnapshot -Root (Join-Path $testRoot 'fixture-main\outside')) `
            -Message 'The build modified content behind a junction.'
    }

    Invoke-TestCase -Run $run -Name 'fixture build refuses to overwrite an existing package unless -Force is given' -Test {
        $fixture = New-PackagingFixture -Root (Join-Path $testRoot 'fixture-force\repo') -Version '2.3.4' `
            -OutsideDirectory (Join-Path $testRoot 'fixture-force\outside')
        $output = Join-Path $testRoot 'fixture-force\output'
        $first = Invoke-PackagingBuild -RepositoryRoot $fixture.Root -OutputDirectory $output
        $firstZipHash = (Get-FileHash -LiteralPath $first.ZipPath -Algorithm SHA256).Hash
        $firstShaText = [IO.File]::ReadAllText($first.Sha256Path)

        Assert-TestThrows -Operation { Invoke-PackagingBuild -RepositoryRoot $fixture.Root -OutputDirectory $output } `
            -Message 'A second build without -Force must be refused.' -ExpectedMessagePattern 'already exists.*-Force'
        Assert-TestEqual -Expected $firstZipHash -Actual (Get-FileHash -LiteralPath $first.ZipPath -Algorithm SHA256).Hash -Message 'A refused build changed the existing ZIP.'
        Assert-TestEqual -Expected $firstShaText -Actual ([IO.File]::ReadAllText($first.Sha256Path)) -Message 'A refused build changed the existing .sha256 file.'

        Write-PackagingFixtureFile -Root $fixture.Root -RelativePath 'README.md' -Text "# 更新后的测试说明`n"
        $second = Invoke-PackagingBuild -RepositoryRoot $fixture.Root -OutputDirectory $output -Force
        Assert-TestFalse ($firstZipHash -eq (Get-FileHash -LiteralPath $second.ZipPath -Algorithm SHA256).Hash) '-Force did not replace the ZIP.'
        [void](Assert-PackagingReleasePackage -ZipPath $second.ZipPath -Version '2.3.4')
        Assert-TestSequenceEqual -Expected @('windows-360-cleaner-v2.3.4.zip', 'windows-360-cleaner-v2.3.4.zip.sha256') `
            -Actual (Get-PackagingDirectoryFileNames -Path $output) -Message 'Replacing the package must not leave partial files behind.'
    }

    Invoke-TestCase -Run $run -Name 'fixture build refuses missing or mismatched version sources and writes nothing' -Test {
        $scenarios = @(
            @{ Name = 'library-mismatch'; Pattern = 'W360ToolVersion = ''1\.2\.2'' but VERSION is ''1\.2\.3'''; Mutate = {
                param($Root) Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Windows360Cleaner.Library.ps1' -PowerShellSource -Text "`$script:W360ToolVersion = '1.2.2'`n" } }
            @{ Name = 'core-missing-constant'; Pattern = 'does not define the version constant \$script:ToolVersion'; Mutate = {
                param($Root) Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Invoke-360Cleanup.ps1' -PowerShellSource -Text "Set-StrictMode -Version 2.0`n" } }
            @{ Name = 'library-file-missing'; Pattern = 'Windows360Cleaner\.Library\.ps1 was not found'; Mutate = {
                param($Root) [IO.File]::Delete((Join-Path $Root 'scripts\Windows360Cleaner.Library.ps1')) } }
            @{ Name = 'core-duplicate-constant'; Pattern = 'assigns \$script:ToolVersion 2 times'; Mutate = {
                param($Root) Write-PackagingFixtureFile -Root $Root -RelativePath 'scripts/Invoke-360Cleanup.ps1' -PowerShellSource -Text "`$script:ToolVersion = '1.2.3'`n`$script:ToolVersion = '1.2.3'`n" } }
            @{ Name = 'changelog-mismatch'; Pattern = 'CHANGELOG\.md top heading is for 1\.2\.4 but VERSION is 1\.2\.3'; Mutate = {
                param($Root) Write-PackagingFixtureFile -Root $Root -RelativePath 'CHANGELOG.md' -Text "# Changelog`n`n## 1.2.4 - 2026-09-13`n" } }
            @{ Name = 'version-malformed'; Pattern = 'VERSION must contain exactly one version'; Mutate = {
                param($Root) Write-PackagingFixtureFile -Root $Root -RelativePath 'VERSION' -Text "v1.2.3`n" } }
        )
        foreach ($scenario in $scenarios) {
            $fixture = New-PackagingFixture -Root (Join-Path $testRoot ('fixture-version-{0}\repo' -f $scenario.Name)) -Version '1.2.3' `
                -OutsideDirectory (Join-Path $testRoot ('fixture-version-{0}\outside' -f $scenario.Name))
            & $scenario.Mutate $fixture.Root
            $output = Join-Path $testRoot ('fixture-version-{0}\output' -f $scenario.Name)
            Assert-TestThrows -Operation { Invoke-PackagingBuild -RepositoryRoot $fixture.Root -OutputDirectory $output } `
                -Message ('Scenario {0} must refuse to build.' -f $scenario.Name) -ExpectedMessagePattern ('(?s)Release build refused.*' + $scenario.Pattern)
            Assert-TestFalse ([IO.Directory]::Exists($output)) ('Scenario {0} created the output directory.' -f $scenario.Name)
        }
    }

    Invoke-TestCase -Run $run -Name 'fixture build refuses unsafe sources and output directories and writes nothing' -Test {
        $scenarios = @(
            @{ Name = 'ps1-without-bom'; Pattern = 'tests/NoBom\.ps1 must be UTF-8 with BOM'; Output = 'output'; Mutate = {
                param($Root) [IO.File]::WriteAllBytes((Join-Path $Root 'tests\NoBom.ps1'), [Text.Encoding]::ASCII.GetBytes("Set-StrictMode -Version 2.0`r`n")) } }
            @{ Name = 'launcher-lf'; Pattern = 'Start-Check\.cmd must use CRLF'; Output = 'output'; Mutate = {
                param($Root) [IO.File]::WriteAllBytes((Join-Path $Root 'Start-Check.cmd'), [Text.Encoding]::ASCII.GetBytes("@echo off`nexit /b 1`n")) } }
            @{ Name = 'template-without-placeholder'; Pattern = 'does not contain the \{\{VERSION\}\} placeholder'; Output = 'output'; Mutate = {
                param($Root) [IO.File]::WriteAllText((Join-Path $Root 'packaging\使用说明.txt'), "使用说明`r`n", (New-Object System.Text.UTF8Encoding($true))) } }
            @{ Name = 'required-launcher-missing'; Pattern = 'Required file 开始检查\.cmd was not found'; Output = 'output'; Mutate = {
                param($Root) [IO.File]::Delete((Join-Path $Root '开始检查.cmd')) } }
            @{ Name = 'output-inside-scripts'; Pattern = 'inside the packaged folder scripts'; Output = 'repo\scripts\release-output'; Mutate = { param($Root) } }
        )
        foreach ($scenario in $scenarios) {
            $fixtureBase = Join-Path $testRoot ('fixture-unsafe-{0}' -f $scenario.Name)
            $fixture = New-PackagingFixture -Root (Join-Path $fixtureBase 'repo') -Version '3.0.0' -OutsideDirectory (Join-Path $fixtureBase 'outside')
            & $scenario.Mutate $fixture.Root
            $output = Join-Path $fixtureBase $scenario.Output
            Assert-TestThrows -Operation { Invoke-PackagingBuild -RepositoryRoot $fixture.Root -OutputDirectory $output } `
                -Message ('Scenario {0} must refuse to build.' -f $scenario.Name) -ExpectedMessagePattern ('(?s)Release build refused.*' + $scenario.Pattern)
            Assert-TestFalse ([IO.Directory]::Exists($output)) ('Scenario {0} created the output directory.' -f $scenario.Name)
        }
    }
}
finally {
    foreach ($junction in @($script:PackagingJunctions)) {
        try {
            if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
        }
        catch {
            Write-Warning ('Could not remove test junction {0}: {1}' -f $junction, $_.Exception.Message)
        }
    }
    if ($testRoot) { Remove-TestDirectory -Path $testRoot }
}

Complete-TestRun -Run $run
