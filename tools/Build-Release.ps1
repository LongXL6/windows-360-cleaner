#requires -Version 5.1
<#
.SYNOPSIS
    Builds the local release package of Windows 360 Cleaner.

.DESCRIPTION
    Reads VERSION and refuses to build unless the core constant ($script:ToolVersion in
    scripts\Invoke-360Cleanup.ps1), the UI library constant ($script:W360ToolVersion in
    scripts\Windows360Cleaner.Library.ps1) and the top heading of CHANGELOG.md carry the same version.

    Files are read from the working tree (uncommitted files are included) and filtered with fixed
    include/exclude lists. Junctions, symbolic links and other reparse points are never packaged.
    packaging\使用说明.txt is rendered with the version and placed in the package root.

    Output: windows-360-cleaner-v<version>.zip (one root folder windows-360-cleaner-v<version>/,
    forward-slash UTF-8 entry names) and windows-360-cleaner-v<version>.zip.sha256 ("<hash>  <file name>").

    The script only creates or replaces those two files inside the output directory (creating the
    directory when needed). It never publishes, uploads, tags, commits or deletes anything else.

.PARAMETER OutputDirectory
    Directory that receives the ZIP and the .sha256 file. Default: <repository>\dist.

.PARAMETER Force
    Replace an existing ZIP and .sha256 of the same version. Without -Force the build refuses.

.PARAMETER RepositoryRoot
    Source tree to package. Default: the folder above tools\. tests\Test-Packaging.ps1 uses it to
    build isolated fixture trees.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$Force,
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ReleasePackagePrefix = 'windows-360-cleaner-v'
$script:ReleaseRootFiles = @('开始检查.cmd', 'Start-Check.cmd', 'README.md', 'README.en.md', 'SKILL.md', 'LICENSE', 'CHANGELOG.md', 'VERSION')
$script:ReleaseRequiredDirectories = @('agents', 'scripts', 'tests', 'references', 'assets/readme')
$script:ReleaseOptionalDirectories = @('assets/screenshots')
$script:ReleaseProtectedSourceDirectories = @('agents', 'scripts', 'tests', 'references', 'assets')
$script:ReleaseExcludedTopLevel = @('docs', 'dist', 'tools', 'packaging')
$script:ReleaseRequiredScripts = @('scripts/Invoke-360Cleanup.ps1', 'scripts/Select-360Cleanup.ps1', 'scripts/Windows360Cleaner.Library.ps1', 'scripts/Show-360Summary.ps1')
$script:ReleaseTemplateRelativePath = 'packaging/使用说明.txt'
$script:ReleaseRenderedGuideName = '使用说明.txt'
$script:ReleaseVersionSources = @(
    [pscustomobject]@{ RelativePath = 'scripts/Invoke-360Cleanup.ps1'; Variable = 'script:ToolVersion' }
    [pscustomobject]@{ RelativePath = 'scripts/Windows360Cleaner.Library.ps1'; Variable = 'script:W360ToolVersion' }
)

function New-ReleaseStrictUtf8Encoding {
    return (New-Object System.Text.UTF8Encoding($false, $true))
}

function Join-ReleasePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    return (Join-Path $Root ($RelativePath.Replace('/', '\')))
}

function Test-ReleaseReparsePoint {
    param([Parameter(Mandatory = $true)][System.IO.FileSystemInfo]$Item)

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-ReleaseIsUnderPath {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    return ($candidateFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or
        $candidateFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase))
}

function Format-ReleaseFoundText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return '<null>' }
    $escaped = $Text.Replace("`r", '\r').Replace("`n", '\n')
    if ($escaped.Length -gt 80) { $escaped = $escaped.Substring(0, 80) + '...' }
    return $escaped
}

function Read-ReleaseText {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    return (New-ReleaseStrictUtf8Encoding).GetString($bytes, $offset, $bytes.Length - $offset)
}

function Get-ReleaseIncludeItem {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    # Walks every path segment so that a linked parent folder (for example a junction named assets) is never followed.
    $current = $Root
    $segments = $RelativePath.Split('/')
    $item = $null
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        $item = $null
        if ([System.IO.Directory]::Exists($current)) { $item = New-Object System.IO.DirectoryInfo -ArgumentList $current }
        elseif ([System.IO.File]::Exists($current)) { $item = New-Object System.IO.FileInfo -ArgumentList $current }

        if ($null -eq $item) {
            return [pscustomobject]@{ Item = $null; Reason = 'Missing'; Path = $current }
        }
        if (Test-ReleaseReparsePoint -Item $item) {
            return [pscustomobject]@{ Item = $null; Reason = 'ReparsePoint'; Path = $current }
        }
        if ($index -lt ($segments.Count - 1) -and -not ($item -is [System.IO.DirectoryInfo])) {
            return [pscustomobject]@{ Item = $null; Reason = 'Missing'; Path = $current }
        }
    }

    return [pscustomobject]@{ Item = $item; Reason = ''; Path = $current }
}

function Test-ReleaseExcludedPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][bool]$IsDirectory
    )

    $segments = $RelativePath.Split('/')
    if ($script:ReleaseExcludedTopLevel -contains $segments[0]) { return $true }

    for ($index = 0; $index -lt $segments.Count; $index++) {
        $segment = $segments[$index]
        if ($segment.StartsWith('.git', [StringComparison]::OrdinalIgnoreCase)) { return $true }
        $isFileLeaf = (-not $IsDirectory) -and ($index -eq ($segments.Count - 1))
        if (-not $isFileLeaf -and $segment -ieq 'reports') { return $true }
    }

    if (-not $IsDirectory) {
        $leaf = $segments[$segments.Count - 1]
        if ($leaf -match '^360-cleanup-.*\.(json|txt)$') { return $true }
        if ($leaf -match '^windows-360-cleaner-progress-.*\.log$') { return $true }
        if ($leaf -match '\.(log|tmp|bak|zip|sha256|partial)$') { return $true }
        if (@('Thumbs.db', 'desktop.ini', '.DS_Store') -contains $leaf) { return $true }
    }

    return $false
}

function Get-ReleaseScriptConstant {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Variable,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $expectedLine = ('${0} = ''{1}''' -f $Variable, $ExpectedVersion)
    $lookup = Get-ReleaseIncludeItem -Root $Root -RelativePath $RelativePath
    if ($null -eq $lookup.Item -or -not ($lookup.Item -is [System.IO.FileInfo])) {
        if ($lookup.Reason -eq 'ReparsePoint') {
            return ('{0} is a junction or symbolic link and cannot be used (expected the line: {1}).' -f $RelativePath, $expectedLine)
        }
        return ('{0} was not found (expected it to contain the line: {1}).' -f $RelativePath, $expectedLine)
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($lookup.Item.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        return ('{0} cannot be parsed, so its version constant cannot be read: {1}' -f $RelativePath, $parseErrors[0].Message)
    }

    $assignments = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
        Where-Object {
            $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $_.Left.VariablePath.UserPath -ieq $Variable
        })

    if ($assignments.Count -eq 0) {
        return ('{0} does not define the version constant ${1}. Expected the line: {2}' -f $RelativePath, $Variable, $expectedLine)
    }
    if ($assignments.Count -gt 1) {
        return ('{0} assigns ${1} {2} times; exactly one constant assignment is required (expected: {3}).' -f `
            $RelativePath, $Variable, $assignments.Count, $expectedLine)
    }

    $assignment = $assignments[0]
    $value = $null
    if ($assignment.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
        $assignment.Right -is [System.Management.Automation.Language.CommandExpressionAst] -and
        $assignment.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
        $assignment.Right.Expression.StringConstantType -eq [System.Management.Automation.Language.StringConstantType]::SingleQuoted) {
        $value = [string]$assignment.Right.Expression.Value
    }

    if ($null -eq $value) {
        return ('{0} assigns ${1} with something other than a single-quoted constant ({2}). Expected the line: {3}' -f `
            $RelativePath, $Variable, (Format-ReleaseFoundText $assignment.Extent.Text), $expectedLine)
    }
    if ($value -cne $ExpectedVersion) {
        return ('{0} defines ${1} = ''{2}'' but VERSION is ''{3}''. Expected the line: {4}' -f `
            $RelativePath, $Variable, (Format-ReleaseFoundText $value), $ExpectedVersion, $expectedLine)
    }

    return ''
}

function Get-ReleaseVersion {
    param([Parameter(Mandatory = $true)][string]$Root)

    $problems = New-Object System.Collections.ArrayList
    $version = $null

    $versionLookup = Get-ReleaseIncludeItem -Root $Root -RelativePath 'VERSION'
    if ($null -eq $versionLookup.Item -or -not ($versionLookup.Item -is [System.IO.FileInfo])) {
        [void]$problems.Add('VERSION was not found in the repository root (or is a link).')
    }
    else {
        $versionText = $null
        try { $versionText = Read-ReleaseText -Path $versionLookup.Item.FullName }
        catch { [void]$problems.Add('VERSION is not valid UTF-8 text.') }
        if ($null -ne $versionText) {
            $versionMatch = [regex]::Match($versionText, '^(\d+\.\d+\.\d+)(\r?\n)?\z')
            if ($versionMatch.Success) { $version = $versionMatch.Groups[1].Value }
            else {
                [void]$problems.Add(('VERSION must contain exactly one version such as 1.0.0 followed by a newline; found "{0}".' -f `
                    (Format-ReleaseFoundText $versionText)))
            }
        }
    }

    $expectedForMessages = $version
    if ($null -eq $expectedForMessages) { $expectedForMessages = '<VERSION>' }

    foreach ($source in $script:ReleaseVersionSources) {
        $problem = Get-ReleaseScriptConstant -Root $Root -RelativePath $source.RelativePath -Variable $source.Variable `
            -ExpectedVersion $expectedForMessages
        if ($problem) { [void]$problems.Add($problem) }
    }

    $changelogLookup = Get-ReleaseIncludeItem -Root $Root -RelativePath 'CHANGELOG.md'
    if ($null -eq $changelogLookup.Item -or -not ($changelogLookup.Item -is [System.IO.FileInfo])) {
        [void]$problems.Add('CHANGELOG.md was not found in the repository root (or is a link).')
    }
    else {
        $changelogText = $null
        try { $changelogText = Read-ReleaseText -Path $changelogLookup.Item.FullName }
        catch { [void]$problems.Add('CHANGELOG.md is not valid UTF-8 text.') }
        if ($null -ne $changelogText) {
            $heading = [regex]::Match($changelogText, '(?m)^##[ \t]+(?!#)(.*?)[ \t]*\r?$')
            $expectedHeading = ('## {0} - yyyy-MM-dd' -f $expectedForMessages)
            if (-not $heading.Success) {
                [void]$problems.Add(('CHANGELOG.md has no release heading. Expected the newest release first as: {0}' -f $expectedHeading))
            }
            else {
                $headingMatch = [regex]::Match($heading.Groups[1].Value, '^(\d+\.\d+\.\d+) - \d{4}-\d{2}-\d{2}$')
                if (-not $headingMatch.Success) {
                    [void]$problems.Add(('CHANGELOG.md top heading "## {0}" does not have the form {1}.' -f `
                        (Format-ReleaseFoundText $heading.Groups[1].Value), $expectedHeading))
                }
                elseif ($null -ne $version -and $headingMatch.Groups[1].Value -cne $version) {
                    [void]$problems.Add(('CHANGELOG.md top heading is for {0} but VERSION is {1}. Expected: {2}' -f `
                        $headingMatch.Groups[1].Value, $version, $expectedHeading))
                }
            }
        }
    }

    if ($problems.Count -gt 0) {
        $lines = @($problems | ForEach-Object { ' - ' + $_ })
        throw ("Release build refused: the version sources are missing or do not match. Nothing was written.{0}{1}" -f `
            [Environment]::NewLine, ($lines -join [Environment]::NewLine))
    }

    return $version
}

function Get-ReleaseSourceFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    $files = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    $problems = New-Object System.Collections.ArrayList

    foreach ($name in $script:ReleaseRootFiles) {
        $lookup = Get-ReleaseIncludeItem -Root $Root -RelativePath $name
        if ($lookup.Reason -eq 'ReparsePoint') {
            [void]$skipped.Add($name)
            [void]$problems.Add(('Required file {0} is a junction or symbolic link and is not packaged.' -f $name))
            continue
        }
        if ($null -eq $lookup.Item -or -not ($lookup.Item -is [System.IO.FileInfo])) {
            [void]$problems.Add(('Required file {0} was not found.' -f $name))
            continue
        }
        [void]$files.Add([pscustomobject]@{ RelativePath = $name; FullPath = $lookup.Item.FullName; LastWriteTime = $lookup.Item.LastWriteTime })
    }

    $directories = @()
    foreach ($directory in $script:ReleaseRequiredDirectories) { $directories += [pscustomobject]@{ RelativePath = $directory; Required = $true } }
    foreach ($directory in $script:ReleaseOptionalDirectories) { $directories += [pscustomobject]@{ RelativePath = $directory; Required = $false } }

    foreach ($directory in $directories) {
        $lookup = Get-ReleaseIncludeItem -Root $Root -RelativePath $directory.RelativePath
        if ($lookup.Reason -eq 'ReparsePoint') {
            [void]$skipped.Add($directory.RelativePath)
            if ($directory.Required) {
                [void]$problems.Add(('Required folder {0} is (or is inside) a junction or symbolic link and is not packaged.' -f $directory.RelativePath))
            }
            continue
        }
        if ($null -eq $lookup.Item -or -not ($lookup.Item -is [System.IO.DirectoryInfo])) {
            if ($directory.Required) { [void]$problems.Add(('Required folder {0} was not found.' -f $directory.RelativePath)) }
            continue
        }

        $stack = New-Object System.Collections.Stack
        $stack.Push([pscustomobject]@{ Directory = $lookup.Item; RelativePath = $directory.RelativePath })
        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            foreach ($child in @($current.Directory.GetFileSystemInfos())) {
                $childRelativePath = $current.RelativePath + '/' + $child.Name
                if (Test-ReleaseReparsePoint -Item $child) {
                    [void]$skipped.Add($childRelativePath)
                    continue
                }
                if ($child -is [System.IO.DirectoryInfo]) {
                    if (-not (Test-ReleaseExcludedPath -RelativePath $childRelativePath -IsDirectory $true)) {
                        $stack.Push([pscustomobject]@{ Directory = $child; RelativePath = $childRelativePath })
                    }
                    continue
                }
                if (Test-ReleaseExcludedPath -RelativePath $childRelativePath -IsDirectory $false) { continue }
                [void]$files.Add([pscustomobject]@{ RelativePath = $childRelativePath; FullPath = $child.FullName; LastWriteTime = $child.LastWriteTime })
            }
        }
    }

    $packagedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $files) { [void]$packagedPaths.Add($file.RelativePath) }
    foreach ($requiredScript in $script:ReleaseRequiredScripts) {
        if (-not $packagedPaths.Contains($requiredScript)) {
            [void]$problems.Add(('Required script {0} was not found.' -f $requiredScript))
        }
    }
    if ($packagedPaths.Contains($script:ReleaseRenderedGuideName)) {
        [void]$problems.Add(('{0} must not exist in the repository root; it is rendered from {1}.' -f `
            $script:ReleaseRenderedGuideName, $script:ReleaseTemplateRelativePath))
    }

    foreach ($file in $files) {
        if ($file.RelativePath -match '\.ps1$') {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullPath)
            if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
                [void]$problems.Add(('{0} must be UTF-8 with BOM (Windows PowerShell 5.1 misreads Chinese text otherwise).' -f $file.RelativePath))
            }
        }
        elseif ($file.RelativePath -match '\.cmd$') {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullPath)
            for ($index = 0; $index -lt $bytes.Length; $index++) {
                $byte = $bytes[$index]
                if ($byte -ge 0x80) {
                    [void]$problems.Add(('{0} must contain ASCII characters only.' -f $file.RelativePath))
                    break
                }
                if (($byte -eq 0x0A -and ($index -eq 0 -or $bytes[$index - 1] -ne 0x0D)) -or
                    ($byte -eq 0x0D -and ($index + 1 -ge $bytes.Length -or $bytes[$index + 1] -ne 0x0A))) {
                    [void]$problems.Add(('{0} must use CRLF line endings.' -f $file.RelativePath))
                    break
                }
            }
        }
    }

    if ($problems.Count -gt 0) {
        $lines = @($problems | ForEach-Object { ' - ' + $_ })
        throw ("Release build refused: the source tree is incomplete or invalid. Nothing was written.{0}{1}" -f `
            [Environment]::NewLine, ($lines -join [Environment]::NewLine))
    }

    $values = $files.ToArray()
    $keys = [string[]]@($values | ForEach-Object { $_.RelativePath })
    # The explicit [Array]/[IComparer] casts select the non-generic overload; the generic one sorts a copy of $values.
    [Array]::Sort([Array]$keys, [Array]$values, [System.Collections.IComparer][StringComparer]::Ordinal)

    return [pscustomobject]@{
        Files   = $values
        Skipped = @($skipped)
    }
}

function Get-ReleaseRenderedGuide {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Version
    )

    $lookup = Get-ReleaseIncludeItem -Root $Root -RelativePath $script:ReleaseTemplateRelativePath
    if ($null -eq $lookup.Item -or -not ($lookup.Item -is [System.IO.FileInfo])) {
        throw ('Release build refused: the template {0} was not found (or is a link). Nothing was written.' -f $script:ReleaseTemplateRelativePath)
    }

    $bytes = [System.IO.File]::ReadAllBytes($lookup.Item.FullName)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        throw ('Release build refused: {0} must be UTF-8 with BOM. Nothing was written.' -f $script:ReleaseTemplateRelativePath)
    }
    $text = (New-ReleaseStrictUtf8Encoding).GetString($bytes, 3, $bytes.Length - 3)
    if (-not $text.Contains('{{VERSION}}')) {
        throw ('Release build refused: {0} does not contain the {{{{VERSION}}}} placeholder. Nothing was written.' -f $script:ReleaseTemplateRelativePath)
    }

    $rendered = $text.Replace('{{VERSION}}', $Version)
    if ($rendered -match '\{\{[A-Za-z0-9_]*\}\}') {
        throw ('Release build refused: {0} contains an unknown placeholder {1}. Nothing was written.' -f $script:ReleaseTemplateRelativePath, $Matches[0])
    }
    $rendered = [regex]::Replace($rendered, "\r\n|\r|\n", "`r`n")

    $memory = New-Object System.IO.MemoryStream
    try {
        $preamble = (New-Object System.Text.UTF8Encoding($true)).GetPreamble()
        $body = (New-Object System.Text.UTF8Encoding($false)).GetBytes($rendered)
        $memory.Write($preamble, 0, $preamble.Length)
        $memory.Write($body, 0, $body.Length)
        return [pscustomobject]@{ Bytes = $memory.ToArray(); LastWriteTime = $lookup.Item.LastWriteTime }
    }
    finally {
        $memory.Dispose()
    }
}

function ConvertTo-ReleaseZipTime {
    param([Parameter(Mandatory = $true)][DateTime]$Time)

    $minimum = New-Object DateTime -ArgumentList 1980, 1, 1, 0, 0, 0, ([DateTimeKind]::Local)
    $maximum = New-Object DateTime -ArgumentList 2107, 12, 31, 0, 0, 0, ([DateTimeKind]::Local)
    if ($Time -lt $minimum) { $Time = $minimum }
    if ($Time -gt $maximum) { $Time = $maximum }
    return (New-Object DateTimeOffset -ArgumentList $Time)
}

function Remove-ReleasePartialFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Delete($Path) }
    }
    catch {
        Write-Warning ('Could not delete the unfinished file {0}: {1}' -f $Path, $_.Exception.Message)
    }
}

function Move-ReleaseFileIntoPlace {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][bool]$Replace
    )

    if ([System.IO.File]::Exists($Destination)) {
        if (-not $Replace) {
            throw ('Release build refused: {0} already exists. Use -Force to replace it.' -f $Destination)
        }
        [System.IO.File]::Delete($Destination)
    }
    [System.IO.File]::Move($Source, $Destination)
}

function Invoke-ReleaseBuild {
    param(
        [AllowEmptyString()][string]$OutputDirectoryValue,
        [Parameter(Mandatory = $true)][bool]$Replace,
        [AllowEmptyString()][string]$RepositoryRootValue
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRootValue)) {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    }
    else {
        $root = [System.IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepositoryRootValue))
    }
    $root = $root.TrimEnd('\')
    if ($root -match '^[A-Za-z]:$') { $root += '\' }
    if (-not [System.IO.Directory]::Exists($root)) {
        throw ('Release build refused: the repository root {0} does not exist.' -f $root)
    }

    if ([string]::IsNullOrWhiteSpace($OutputDirectoryValue)) {
        $output = Join-Path $root 'dist'
    }
    else {
        $output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectoryValue)
    }
    $output = [System.IO.Path]::GetFullPath($output).TrimEnd('\')
    if ($output -match '^[A-Za-z]:$') { $output += '\' }

    foreach ($protected in $script:ReleaseProtectedSourceDirectories) {
        $protectedPath = Join-ReleasePath -Root $root -RelativePath $protected
        if (Test-ReleaseIsUnderPath -Candidate $output -Root $protectedPath) {
            throw ('Release build refused: the output directory {0} is inside the packaged folder {1}. Choose another directory (default: dist).' -f `
                $output, $protected)
        }
    }
    if ([System.IO.File]::Exists($output)) {
        throw ('Release build refused: the output path {0} is a file, not a directory.' -f $output)
    }
    if ([System.IO.Directory]::Exists($output)) {
        $outputInfo = New-Object System.IO.DirectoryInfo -ArgumentList $output
        if (Test-ReleaseReparsePoint -Item $outputInfo) {
            throw ('Release build refused: the output directory {0} is a junction or symbolic link.' -f $output)
        }
    }

    $version = Get-ReleaseVersion -Root $root
    $source = Get-ReleaseSourceFiles -Root $root
    $guide = Get-ReleaseRenderedGuide -Root $root -Version $version

    $packageRoot = $script:ReleasePackagePrefix + $version
    $zipName = $packageRoot + '.zip'
    $zipPath = Join-Path $output $zipName
    $shaPath = $zipPath + '.sha256'

    foreach ($existing in @($zipPath, $shaPath)) {
        if ([System.IO.Directory]::Exists($existing)) {
            throw ('Release build refused: {0} exists as a directory.' -f $existing)
        }
        if ([System.IO.File]::Exists($existing)) {
            $existingInfo = New-Object System.IO.FileInfo -ArgumentList $existing
            if (Test-ReleaseReparsePoint -Item $existingInfo) {
                throw ('Release build refused: {0} is a link; it will not be replaced.' -f $existing)
            }
            if (-not $Replace) {
                throw ('Release build refused: {0} already exists. Use -Force to replace it. Nothing was written.' -f $existing)
            }
        }
    }

    $fileEntries = New-Object System.Collections.Generic.List[object]
    foreach ($file in $source.Files) {
        $fileEntries.Add([pscustomobject]@{
            Name          = $packageRoot + '/' + $file.RelativePath
            FullPath      = $file.FullPath
            Bytes         = $null
            LastWriteTime = $file.LastWriteTime
        })
    }
    $fileEntries.Add([pscustomobject]@{
        Name          = $packageRoot + '/' + $script:ReleaseRenderedGuideName
        FullPath      = $null
        Bytes         = $guide.Bytes
        LastWriteTime = $guide.LastWriteTime
    })
    $fileEntries.Sort([Comparison[object]] { param($left, $right) [string]::CompareOrdinal($left.Name, $right.Name) })

    $directoryNames = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    [void]$directoryNames.Add($packageRoot + '/')
    $newestFileTime = $guide.LastWriteTime
    foreach ($entry in $fileEntries) {
        if ($entry.LastWriteTime -gt $newestFileTime) { $newestFileTime = $entry.LastWriteTime }
        if ($entry.Name.Contains('\') -or $entry.Name.Contains('//') -or $entry.Name -match '(^|/)\.\.?(/|$)') {
            throw ('Release build refused: invalid entry name {0}.' -f $entry.Name)
        }
        $slash = $entry.Name.LastIndexOf('/')
        while ($slash -gt 0) {
            [void]$directoryNames.Add($entry.Name.Substring(0, $slash + 1))
            $slash = $entry.Name.LastIndexOf('/', $slash - 1)
        }
    }

    Add-Type -AssemblyName System.IO.Compression

    if (-not [System.IO.Directory]::Exists($output)) {
        [void][System.IO.Directory]::CreateDirectory($output)
    }

    $token = [Guid]::NewGuid().ToString('N')
    $partialZip = Join-Path $output ('{0}.{1}.partial' -f $zipName, $token)
    $partialSha = Join-Path $output ('{0}.sha256.{1}.partial' -f $zipName, $token)
    $expectedEntryCount = $directoryNames.Count + $fileEntries.Count
    $hash = $null

    try {
        $stream = New-Object System.IO.FileStream -ArgumentList $partialZip, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::ReadWrite), ([System.IO.FileShare]::None)
        try {
            # Must be exactly [Text.Encoding]::UTF8: .NET Framework only sets the ZIP UTF-8 name flag (bit 11) when the
            # encoding Equals Encoding.UTF8, and a new UTF8Encoding($false) does not. Without the flag, Explorer and
            # ZipArchive on Chinese Windows decode names such as 开始检查.cmd with the ANSI/OEM code page.
            $archive = New-Object System.IO.Compression.ZipArchive -ArgumentList $stream, ([System.IO.Compression.ZipArchiveMode]::Create), $true, ([System.Text.Encoding]::UTF8)
            try {
                foreach ($directoryName in $directoryNames) {
                    $directoryEntry = $archive.CreateEntry($directoryName)
                    $directoryEntry.LastWriteTime = ConvertTo-ReleaseZipTime -Time $newestFileTime
                }

                foreach ($entry in $fileEntries) {
                    $zipEntry = $archive.CreateEntry($entry.Name, [System.IO.Compression.CompressionLevel]::Optimal)
                    $zipEntry.LastWriteTime = ConvertTo-ReleaseZipTime -Time $entry.LastWriteTime
                    $entryStream = $zipEntry.Open()
                    try {
                        if ($null -ne $entry.Bytes) {
                            $entryStream.Write($entry.Bytes, 0, $entry.Bytes.Length)
                        }
                        else {
                            $attributes = [System.IO.File]::GetAttributes($entry.FullPath)
                            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                                throw ('Release build refused: {0} became a link while building.' -f $entry.FullPath)
                            }
                            $sourceStream = New-Object System.IO.FileStream -ArgumentList $entry.FullPath, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::Read)
                            try { $sourceStream.CopyTo($entryStream) }
                            finally { $sourceStream.Dispose() }
                        }
                    }
                    finally {
                        $entryStream.Dispose()
                    }
                }
            }
            finally {
                $archive.Dispose()
            }
            $stream.Flush()
        }
        finally {
            $stream.Dispose()
        }

        $checkStream = New-Object System.IO.FileStream -ArgumentList $partialZip, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::Read)
        try {
            $checkArchive = New-Object System.IO.Compression.ZipArchive -ArgumentList $checkStream, ([System.IO.Compression.ZipArchiveMode]::Read), $false
            try {
                if ($checkArchive.Entries.Count -ne $expectedEntryCount) {
                    throw ('Release build failed: the ZIP has {0} entries, expected {1}.' -f $checkArchive.Entries.Count, $expectedEntryCount)
                }
                $expectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
                foreach ($directoryName in $directoryNames) { [void]$expectedNames.Add($directoryName) }
                foreach ($entry in $fileEntries) { [void]$expectedNames.Add($entry.Name) }
                foreach ($checkEntry in $checkArchive.Entries) {
                    # Read back without an explicit encoding, as other tools do: names only match if the UTF-8 flag is set.
                    if (-not $expectedNames.Contains($checkEntry.FullName)) {
                        throw ('Release build failed: the entry name {0} did not read back as UTF-8.' -f $checkEntry.FullName)
                    }
                }
            }
            finally {
                $checkArchive.Dispose()
            }
        }
        finally {
            $checkStream.Dispose()
        }

        $hash = (Get-FileHash -LiteralPath $partialZip -Algorithm SHA256).Hash.ToLowerInvariant()
        $shaBytes = [System.Text.Encoding]::ASCII.GetBytes(('{0}  {1}' -f $hash, $zipName) + "`n")
        $shaStream = New-Object System.IO.FileStream -ArgumentList $partialSha, ([System.IO.FileMode]::CreateNew), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::None)
        try { $shaStream.Write($shaBytes, 0, $shaBytes.Length) }
        finally { $shaStream.Dispose() }

        Move-ReleaseFileIntoPlace -Source $partialZip -Destination $zipPath -Replace $Replace
        Move-ReleaseFileIntoPlace -Source $partialSha -Destination $shaPath -Replace $Replace
    }
    finally {
        Remove-ReleasePartialFile -Path $partialZip
        Remove-ReleasePartialFile -Path $partialSha
    }

    foreach ($skippedPath in $source.Skipped) {
        Write-Warning ('Skipped a junction or symbolic link (not packaged): {0}' -f $skippedPath)
    }
    Write-Host ('Release package: {0}' -f $zipPath)
    Write-Host ('SHA-256 file:    {0}' -f $shaPath)
    Write-Host ('SHA-256:         {0}' -f $hash)
    Write-Host ('Entries: {0} ({1} files). Nothing was published or uploaded.' -f $expectedEntryCount, $fileEntries.Count)

    return [pscustomobject]@{
        Version              = $version
        PackageRoot          = $packageRoot
        ZipPath              = $zipPath
        Sha256Path           = $shaPath
        Sha256               = $hash
        EntryCount           = $expectedEntryCount
        FileCount            = $fileEntries.Count
        SkippedReparsePoints = @($source.Skipped)
    }
}

Invoke-ReleaseBuild -OutputDirectoryValue $OutputDirectory -Replace ([bool]$Force) -RepositoryRootValue $RepositoryRoot
