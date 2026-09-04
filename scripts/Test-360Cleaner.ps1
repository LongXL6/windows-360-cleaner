[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Invoke-360Cleanup.ps1'
$removeCmd = Join-Path $PSScriptRoot 'Remove-360.cmd'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestFinding {
    param([string]$Target)
    [pscustomobject]@{
        Kind = 'Path'; Name = 'Isolated test target'; Target = $Target
        Confidence = 'Confirmed'; Reason = 'Isolated test fixture'
        RemovalType = 'Path'; ValueName = ''; Offline = $false
    }
}

function Invoke-RemoveCmdInput {
    param(
        [string]$Path,
        [string]$InputText,
        [bool]$SendInput
    )
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'cmd.exe'
    $startInfo.Arguments = '/d /c call "' + $Path + '"'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    if ($SendInput) { $process.StandardInput.WriteLine($InputText) }
    $process.StandardInput.Close()
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
}

function Invoke-CleanupScriptProcess {
    param([string]$ArgumentLine)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = 'powershell.exe'
    $startInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath + '" ' + $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
}

$tokens = $null
$parseErrors = $null
foreach ($sourcePath in @($scriptPath, $PSCommandPath)) {
    $sourceBytes = [IO.File]::ReadAllBytes($sourcePath)
    Assert-True ($sourceBytes.Length -ge 3 -and $sourceBytes[0] -eq 0xEF -and $sourceBytes[1] -eq 0xBB -and $sourceBytes[2] -eq 0xBF) `
        "PowerShell 5.1 compatibility requires a UTF-8 BOM: $sourcePath"
}
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error $_.Message }
    throw 'PowerShell parser validation failed.'
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('windows-360-cleaner-safety-{0}' -f [Guid]::NewGuid().ToString('N'))
$scanReport = Join-Path $fixtureRoot 'read-only-scan.json'
$existingReport = Join-Path $fixtureRoot 'do-not-overwrite.json'
$wrongExtension = Join-Path $fixtureRoot 'do-not-overwrite.txt'

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null

    & $scriptPath -Mode Scan -ReportPath $scanReport
    Assert-True (Test-Path -LiteralPath $scanReport) 'Scan did not create a report.'
    $json = Get-Content -LiteralPath $scanReport -Raw | ConvertFrom-Json
    Assert-True ($json.SchemaVersion -eq 2 -and [bool]$json.Timestamp -and $json.Mode -eq 'Scan' -and
        $null -ne $json.Findings -and $null -ne $json.ApprovalContext) 'Report schema is incomplete.'
    Assert-True ($json.PSObject.Properties.Name -contains 'Summary') 'Report schema must expose a Summary field.'
    Assert-True ($null -eq $json.Summary) 'A read-only scan must not claim that content was removed.'
    Assert-True ($null -eq $json.ComputerName -and $null -eq $json.User) 'Reports must omit local identity by default.'

    $env:WINDOWS_360_CLEANER_TEST_MODE = 'ISOLATED-SAFETY-TEST'
    try { . $scriptPath -InternalTestLibraryOnly }
    finally { Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue }
    $originalKnownFolders = $script:KnownFolders
    $script:KnownFolders = [ordered]@{
        LocalAppData = Join-Path $fixtureRoot 'LocalAppData'
        RoamingAppData = Join-Path $fixtureRoot 'RoamingAppData'
        ProgramFiles = Join-Path $fixtureRoot 'ProgramFiles'
        ProgramFilesX86 = Join-Path $fixtureRoot 'ProgramFilesX86'
        ProgramData = Join-Path $fixtureRoot 'ProgramData'
        UserProfile = Join-Path $fixtureRoot 'UserProfile'
        Desktop = Join-Path $fixtureRoot 'Desktop'
        Temp = Join-Path $fixtureRoot 'Temp'
        Windows = Join-Path $fixtureRoot 'Windows'
    }
    foreach ($path in $script:KnownFolders.Values) { New-Item -ItemType Directory -Path $path -Force | Out-Null }

    Set-Content -LiteralPath $existingReport -Value 'KEEP-REPORT' -Encoding UTF8
    $existingHash = (Get-FileHash -LiteralPath $existingReport -Algorithm SHA256).Hash
    $overwriteBlocked = $false
    try { Save-CleanupReport -Path $existingReport -RunMode Scan -Findings @() -Actions @() }
    catch { $overwriteBlocked = $true }
    Assert-True $overwriteBlocked 'Existing report paths must never be overwritten.'
    Assert-True ((Get-FileHash -LiteralPath $existingReport -Algorithm SHA256).Hash -eq $existingHash) 'Existing report content changed.'
    $extensionBlocked = $false
    try { Save-CleanupReport -Path $wrongExtension -RunMode Scan -Findings @() -Actions @() }
    catch { $extensionBlocked = $true }
    Assert-True $extensionBlocked 'Non-JSON report paths must be rejected.'

    Assert-True (-not (Test-SafeRemovalTarget $script:KnownFolders.Temp)) 'A broad temporary root must never be removable.'
    $deduplicated = @(Get-TopLevelAccountingTargets @('C:\isolated-root', 'C:\isolated-root\child', 'D:\separate-root'))
    Assert-True ($deduplicated.Count -eq 2 -and $deduplicated -contains 'C:\isolated-root' -and $deduplicated -contains 'D:\separate-root') `
        'Nested path targets must be deduplicated before removal accounting.'
    $normal360 = Join-Path $script:KnownFolders.UserProfile 'Documents\360'
    New-Item -ItemType Directory -Path $normal360 -Force | Out-Null
    $normalFile = Join-Path $normal360 'family-photo-360.txt'
    Set-Content -LiteralPath $normalFile -Value 'KEEP-NORMAL-FILE'
    $normalHash = (Get-FileHash -LiteralPath $normalFile -Algorithm SHA256).Hash
    Assert-True (-not (Test-SafeRemovalTarget $normal360)) 'A normal user folder named 360 must not pass the removal allowlist.'

    $tooMany = @(1..65 | ForEach-Object { New-TestFinding (Join-Path $script:KnownFolders.Temp ("untrusted-target-{0}" -f $_)) })
    $limitBlocked = $false
    try { [void](Remove-ConfirmedFindings -Findings $tooMany) }
    catch { $limitBlocked = $true }
    Assert-True $limitBlocked 'More than 64 path targets must fail before any mutation.'

    $outside = Join-Path $fixtureRoot 'outside-canary'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $outsideFile = Join-Path $outside 'keep.txt'
    Set-Content -LiteralPath $outsideFile -Value 'KEEP-OUTSIDE'
    $outsideHash = (Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash
    $reparseTarget = Join-Path $script:KnownFolders.Temp 'duohuipingbao'
    New-Item -ItemType Directory -Path $reparseTarget | Out-Null
    $junction = Join-Path $reparseTarget 'escape'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-True (-not (Test-SafeRemovalTarget $reparseTarget)) 'A target containing a junction must fail closed.'
    $reparseBlocked = $false
    try { [void](Remove-ConfirmedFindings -Findings @((New-TestFinding $reparseTarget))) }
    catch { $reparseBlocked = $true }
    Assert-True $reparseBlocked 'A reparse-point target must fail the complete removal preflight.'
    Assert-True (Test-Path -LiteralPath $reparseTarget) 'A target containing a junction was deleted.'
    Assert-True ((Get-FileHash -LiteralPath $outsideFile -Algorithm SHA256).Hash -eq $outsideHash) 'The external junction canary changed.'
    [IO.Directory]::Delete($junction)
    Remove-Item -LiteralPath $reparseTarget -Recurse -Force

    $safeTarget = Join-Path $script:KnownFolders.Temp 'duohuipingbao'
    New-Item -ItemType Directory -Path $safeTarget | Out-Null
    Set-Content -LiteralPath (Join-Path $safeTarget 'payload.tmp') -Value 'ISOLATED-PAYLOAD'
    $safeSummary = [ordered]@{}
    $safeActions = @(Remove-ConfirmedFindings -Findings @((New-TestFinding $safeTarget)) -Summary $safeSummary)
    Assert-True (-not (Test-Path -LiteralPath $safeTarget)) 'The isolated exact allowlisted target was not deleted.'
    Assert-True (@($safeActions | Where-Object { $_.Action -eq 'DeletePath' -and $_.Result -eq 'Success' }).Count -eq 1) 'Successful isolated deletion was not recorded.'
    Assert-True ($safeSummary.PathAccountingComplete -and $safeSummary.FilesRemoved -eq 1 -and $safeSummary.DirectoriesRemoved -eq 1) `
        'The removal summary did not count the isolated file and its parent directory.'
    Assert-True ($safeSummary.TotalItemsRemoved -eq 2 -and $safeSummary.LogicalBytesRemoved -gt 0 -and [bool]$safeSummary.LogicalSizeRemoved) `
        'The removal summary did not expose total items and logical file size.'
    Assert-True (-not $safeSummary.Contains('FreedSpace')) 'The summary must not mislabel logical file size as actual freed disk space.'
    Assert-True ($safeSummary.Contains('NoImmediateConfirmedFindings') -and -not $safeSummary.Contains('ImmediateRescanPassed')) `
        'The summary must not describe a confirmed-finding count as an overall rescan pass.'
    $summaryReport = Join-Path $fixtureRoot 'removal-summary.json'
    Save-CleanupReport -Path $summaryReport -RunMode Remove -Findings @() -Actions $safeActions -Summary $safeSummary
    $summaryJson = Get-Content -LiteralPath $summaryReport -Raw | ConvertFrom-Json
    Assert-True ($summaryJson.Summary.TotalItemsRemoved -eq 2 -and $summaryJson.Summary.FilesRemoved -eq 1) `
        'The JSON report did not preserve the removal summary.'
    $repeatSummary = [ordered]@{}
    $repeatActions = @(Remove-ConfirmedFindings -Findings @((New-TestFinding $safeTarget)) -Summary $repeatSummary)
    Assert-True ($repeatActions.Count -eq 0) 'Repeated cleanup of an absent target should be a no-op.'
    Assert-True ($repeatSummary.PathAccountingComplete -and $repeatSummary.TotalItemsRemoved -eq 0 -and $repeatSummary.LogicalBytesRemoved -eq 0) `
        'Repeated cleanup must report an accurate zero total.'

    $lockedTarget = Join-Path $script:KnownFolders.Temp 'huabao_tmp'
    New-Item -ItemType Directory -Path $lockedTarget | Out-Null
    $lockedFile = Join-Path $lockedTarget 'locked.bin'
    Set-Content -LiteralPath $lockedFile -Value 'LOCKED'
    $lockStream = New-Object IO.FileStream($lockedFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lockedSummary = [ordered]@{}
        $lockedActions = @(Remove-ConfirmedFindings -Findings @((New-TestFinding $lockedTarget)) -Summary $lockedSummary)
        Assert-True (Test-Path -LiteralPath $lockedTarget) 'A locked target was force-deleted in default mode.'
        Assert-True (@($lockedActions | Where-Object { $_.Action -eq 'DeletePathRetry' -and $_.Result -eq 'Skipped' }).Count -ge 1) 'Default locked-target refusal was not recorded.'
        Assert-True ($lockedSummary.RetryAttempts -eq 1 -and $lockedSummary.UnresolvedRetryTargets -eq 1) `
            'Retry attempts and final unresolved retry targets must be reported separately.'
    }
    finally { $lockStream.Dispose() }
    Remove-Item -LiteralPath $lockedTarget -Recurse -Force

    $browserProfile = Join-Path $script:KnownFolders.LocalAppData '360Chrome\Chrome\User Data'
    New-Item -ItemType Directory -Path $browserProfile | Out-Null
    $bookmarks = Join-Path $browserProfile 'Bookmarks'
    Set-Content -LiteralPath $bookmarks -Value 'KEEP-BOOKMARKS'
    $bookmarksHash = (Get-FileHash -LiteralPath $bookmarks -Algorithm SHA256).Hash
    $defaultFindings = @(Get-360Findings -IncludeProfiles:$false)
    $browserDefault = @($defaultFindings | Where-Object { $_.Target -eq (Get-NormalPath $browserProfile) })
    Assert-True ($browserDefault.Count -eq 1 -and $browserDefault[0].Confidence -eq 'ReviewOnly') 'Browser profiles must be ReviewOnly by default.'
    $optInFindings = @(Get-360Findings -IncludeProfiles:$true)
    $browserOptIn = @($optInFindings | Where-Object { $_.Target -eq (Get-NormalPath $browserProfile) })
    Assert-True ($browserOptIn.Count -eq 1 -and $browserOptIn[0].Confidence -eq 'Confirmed') 'Explicit browser-profile opt-in was not represented.'

    $softMgrFake = Join-Path $script:KnownFolders.LocalAppData 'winToolBox\Tools\SoftMgrFake'
    New-Item -ItemType Directory -Path $softMgrFake -Force | Out-Null
    foreach ($name in @('360Base.dll', '360Conf.dll', '360NetBase.dll', '360Util.dll')) { New-Item -ItemType File -Path (Join-Path $softMgrFake $name) | Out-Null }
    Assert-True (-not (Test-SoftMgrEvidence $softMgrFake)) 'Marker filenames without 360 metadata/signatures must not confirm SoftMgr.'
    foreach ($preserved in @('kantu', 'clear', 'pdf', 'zip')) {
        $path = Join-Path $script:KnownFolders.LocalAppData ('winToolBox\Tools\' + $preserved)
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Assert-True (-not (Test-IsExpectedRemovalPath $path)) "winToolBox $preserved must not be allowlisted for deletion."
    }

    $offlineRoot = Join-Path $fixtureRoot 'OfflineWindows'
    New-Item -ItemType Directory -Path (Join-Path $offlineRoot 'Windows') -Force | Out-Null
    $offline360 = Join-Path $offlineRoot 'Program Files\360'
    New-Item -ItemType Directory -Path $offline360 -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $offline360 'keep.bin') -Value 'OFFLINE-KEEP'
    $offlineFindings = @(Get-360Findings -OfflineRoot $offlineRoot)
    $offlineMatch = @($offlineFindings | Where-Object { $_.Target -eq (Get-NormalPath $offline360) })
    Assert-True ($offlineMatch.Count -eq 1 -and $offlineMatch[0].Confidence -eq 'ReviewOnly' -and $offlineMatch[0].Offline) 'Offline Windows findings must remain scan-only.'

    $missingPhraseReport = Join-Path $fixtureRoot 'missing-phrase.json'
    $missingPhrase = Invoke-CleanupScriptProcess ('-Mode Remove -ApprovedReport "{0}" -ConfirmRemoval -ReportPath "{1}"' -f $scanReport, $missingPhraseReport)
    Assert-True ($missingPhrase.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $missingPhraseReport) -and
        $missingPhrase.Output.Contains('Removal requires the exact phrase')) `
        'Remove without the exact phrase must fail for that reason before elevation or mutation.'
    $profilePhraseReport = Join-Path $fixtureRoot 'missing-profile-phrase.json'
    $missingProfilePhrase = Invoke-CleanupScriptProcess ('-Mode Remove -ApprovedReport "{0}" -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 -IncludeBrowserProfiles -ReportPath "{1}"' -f $scanReport, $profilePhraseReport)
    Assert-True ($missingProfilePhrase.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $profilePhraseReport) -and
        $missingProfilePhrase.Output.Contains('Deleting browser profiles requires the separate exact phrase')) `
        'Browser-profile deletion without its separate phrase must fail for that reason before elevation or mutation.'
    $offlineRemoveReport = Join-Path $fixtureRoot 'offline-remove.json'
    $offlineRemove = Invoke-CleanupScriptProcess ('-Mode Remove -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 -OfflineWindowsRoot "{0}" -ReportPath "{1}"' -f $offlineRoot, $offlineRemoveReport)
    Assert-True ($offlineRemove.ExitCode -ne 0 -and -not (Test-Path -LiteralPath $offlineRemoveReport)) 'Offline Windows removal must fail before elevation or mutation.'

    $cancel = Invoke-RemoveCmdInput -Path $removeCmd -InputText 'N' -SendInput $true
    Assert-True ($cancel.ExitCode -eq 2) 'User cancellation must return exit code 2, not success.'
    $invalid = Invoke-RemoveCmdInput -Path $removeCmd -InputText '' -SendInput $false
    Assert-True ($invalid.ExitCode -eq 64) 'Missing/invalid input must return exit code 64, not success.'
    $wrongPhrase = Invoke-RemoveCmdInput -Path $removeCmd -InputText 'YWRONG' -SendInput $true
    Assert-True ($wrongPhrase.ExitCode -eq 3) 'A wrong second confirmation phrase must stop before PowerShell or UAC.'
    $missingApproved = Invoke-RemoveCmdInput -Path $removeCmd -InputText 'YREMOVE-360' -SendInput $true
    Assert-True ($missingApproved.ExitCode -eq 4) `
        ("An empty approved-report prompt must stop before PowerShell or UAC. Output: {0}" -f $missingApproved.Output)
    $missingApprovedPath = Join-Path $fixtureRoot 'does-not-exist.json'
    $missingApprovedFile = Invoke-RemoveCmdInput -Path $removeCmd `
        -InputText ("YREMOVE-360`r`n{0}" -f $missingApprovedPath) -SendInput $true
    Assert-True ($missingApprovedFile.ExitCode -eq 4) 'A missing approved report must stop before PowerShell or UAC.'
    $notJsonDirectory = Join-Path $fixtureRoot 'approved report fixtures'
    New-Item -ItemType Directory -Path $notJsonDirectory | Out-Null
    $notJsonPath = Join-Path $notJsonDirectory 'not-approved.txt'
    Set-Content -LiteralPath $notJsonPath -Value 'NOT-AN-APPROVED-REPORT'
    $quotedNotJsonInput = "YREMOVE-360`r`n" + '"' + $notJsonPath + '"'
    $notJson = Invoke-RemoveCmdInput -Path $removeCmd `
        -InputText $quotedNotJsonInput -SendInput $true
    Assert-True ($notJson.ExitCode -eq 4) 'A non-JSON approved report must stop before PowerShell or UAC.'
    Assert-True ((Get-FileHash -LiteralPath $normalFile -Algorithm SHA256).Hash -eq $normalHash) 'A normal user file changed during the safety suite.'
    Assert-True ((Get-FileHash -LiteralPath $bookmarks -Algorithm SHA256).Hash -eq $bookmarksHash) 'Browser bookmarks changed without the destructive opt-in.'

    $script:KnownFolders = $originalKnownFolders
    Write-Host 'Syntax, read-only scan, and isolated safety tests passed.' -ForegroundColor Green
}
finally {
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        $remainingJunction = Join-Path $fixtureRoot 'Temp\duohuipingbao\escape'
        if (Test-Path -LiteralPath $remainingJunction) {
            try { [IO.Directory]::Delete($remainingJunction) }
            catch {}
        }
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$additionalSuites = @(
    (Join-Path $PSScriptRoot '..\tests\Test-Detector.ps1')
    (Join-Path $PSScriptRoot '..\tests\Test-Elevation.ps1')
    (Join-Path $PSScriptRoot '..\tests\Test-Approval.ps1')
)
foreach ($suitePath in $additionalSuites) {
    Write-Host ("Running {0}..." -f (Split-Path -Leaf $suitePath)) -ForegroundColor Cyan
    & $suitePath -CleanerScriptPath $scriptPath
}

Write-Host 'All Windows 360 Cleaner test suites passed.' -ForegroundColor Green
