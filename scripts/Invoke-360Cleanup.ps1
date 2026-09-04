#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Remove', 'Verify')]
    [string]$Mode = 'Scan',

    [switch]$ConfirmRemoval,

    [string]$ConfirmationPhrase,

    [switch]$IncludeBrowserProfiles,

    [string]$BrowserProfileConfirmation,

    [switch]$AllowExplorerRestart,

    [switch]$ForceLockedTargets,

    [switch]$IncludeIdentityInReport,

    [string]$OfflineWindowsRoot,

    [string]$ReportPath,

    [string]$ApprovedReport,

    [string]$ApprovedReportHash,

    [string]$OutcomeRunId,

    [switch]$InternalElevatedChild,

    [switch]$InternalTestLibraryOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'Windows 360 Cleaner only supports Windows.'
}

try {
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
}
catch {}

$script:KnownFolders = [ordered]@{
    LocalAppData   = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    RoamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    ProgramFiles   = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)
    ProgramFilesX86 = [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)
    ProgramData    = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    UserProfile    = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    Desktop        = [Environment]::GetFolderPath([Environment+SpecialFolder]::Desktop)
    Temp           = [IO.Path]::GetTempPath().TrimEnd('\')
    Windows        = Split-Path -Parent ([Environment]::SystemDirectory)
}

$script:CleanupRuntimeProvider = $null
$script:CleanupRuntimeProviderContext = $null
$script:CurrentUserRegistryRoot = 'HKCU:'

function Set-360CleanupRuntimeProvider {
    param(
        [System.Collections.IDictionary]$Provider,
        [object]$Context = $null
    )

    $allowedNames = @(
        'RegistryPathExists', 'RegistrySubKeys', 'RegistryValues',
        'ScheduledTasks', 'Services', 'Processes',
        'IsAdministrator', 'StartElevatedProcess', 'StopProcess', 'Is360File',
        'PathItem', 'PathChildren', 'RemovePath', 'RepairPathAcl',
        'StartVendorUninstaller', 'IsTrustedDuohuiVendorFile'
    )
    $replacement = @{}
    foreach ($name in @($Provider.Keys)) {
        $providerName = [string]$name
        if ($allowedNames -notcontains $providerName) {
            throw "Unknown cleanup runtime provider: $providerName"
        }
        if (-not ($Provider[$name] -is [scriptblock])) {
            throw "Cleanup runtime provider '$providerName' must be a script block."
        }
        $replacement[$providerName] = $Provider[$name]
    }
    foreach ($requiredName in $allowedNames) {
        if (-not $replacement.ContainsKey($requiredName)) {
            throw "Cleanup runtime provider is missing required operation: $requiredName"
        }
    }
    $script:CleanupRuntimeProvider = $replacement
    $script:CleanupRuntimeProviderContext = $Context
}

function Reset-360CleanupRuntimeProvider {
    $script:CleanupRuntimeProvider = $null
    $script:CleanupRuntimeProviderContext = $null
}

function Invoke-360CleanupRuntimeProvider {
    param(
        [string]$Name,
        [scriptblock]$Default,
        [object[]]$ArgumentList = @()
    )

    if ($null -ne $script:CleanupRuntimeProvider) {
        if (-not $script:CleanupRuntimeProvider.ContainsKey($Name)) {
            throw "Cleanup runtime provider is missing required operation: $Name"
        }
        $implementation = $script:CleanupRuntimeProvider[$Name]
        return & $implementation $script:CleanupRuntimeProviderContext @ArgumentList
    }
    return & $Default @ArgumentList
}

function Test-360CleanupRegistryPath {
    param([string]$Path)

    return [bool](Invoke-360CleanupRuntimeProvider -Name 'RegistryPathExists' -ArgumentList @($Path) -Default {
        param($RegistryPath)
        Test-Path -LiteralPath $RegistryPath
    })
}

function Get-360CleanupRegistrySubKeys {
    param([string]$Path)

    return @(Invoke-360CleanupRuntimeProvider -Name 'RegistrySubKeys' -ArgumentList @($Path) -Default {
        param($RegistryPath)
        Get-ChildItem -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    })
}

function Get-360CleanupRegistryValues {
    param([string]$Path)

    return Invoke-360CleanupRuntimeProvider -Name 'RegistryValues' -ArgumentList @($Path) -Default {
        param($RegistryPath)
        Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction SilentlyContinue
    }
}

function Get-360CleanupScheduledTasks {
    return @(Invoke-360CleanupRuntimeProvider -Name 'ScheduledTasks' -Default {
        Get-ScheduledTask -ErrorAction SilentlyContinue
    })
}

function Get-360CleanupServices {
    return @(Invoke-360CleanupRuntimeProvider -Name 'Services' -Default {
        Get-CimInstance Win32_Service -ErrorAction SilentlyContinue
    })
}

function Get-360CleanupProcesses {
    return @(Invoke-360CleanupRuntimeProvider -Name 'Processes' -Default {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    })
}

function Stop-360CleanupProcess {
    param(
        [int]$ProcessId,
        [string]$ExpectedExecutable
    )

    return Invoke-360CleanupRuntimeProvider -Name 'StopProcess' `
        -ArgumentList @($ProcessId, $ExpectedExecutable) -Default {
        param($Id, $ExpectedPath)

        $expected = Get-NormalPath ([string]$ExpectedPath)
        if (-not $expected) {
            return [pscustomobject]@{
                Target = [string]$Id; Result = 'Skipped'; Detail = 'The approved executable path is invalid.'
            }
        }

        $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
        if ($null -eq $process) {
            return [pscustomobject]@{
                Target = [string]$Id; Result = 'Skipped'; Detail = 'The approved process has already exited.'
            }
        }

        try { $actual = Get-NormalPath ([string]$process.Path) }
        catch { $actual = $null }
        if (-not $actual -or -not $actual.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{
                Target = [string]$Id; Result = 'Skipped'
                Detail = 'PID executable no longer matches the executable confirmed during the elevated rescan.'
            }
        }

        $target = ('{0} ({1})' -f $process.ProcessName, $Id)
        try {
            # Keep the validated Process object so Kill uses that process handle rather than resolving the PID again.
            $process.Kill()
            if (-not $process.WaitForExit(5000)) {
                return [pscustomobject]@{
                    Target = $target; Result = 'Failed'; Detail = 'The process did not exit within five seconds.'
                }
            }
            return [pscustomobject]@{ Target = $target; Result = 'Success'; Detail = $actual }
        }
        catch {
            return [pscustomobject]@{ Target = $target; Result = 'Failed'; Detail = $_.Exception.Message }
        }
    }
}

function Start-360CleanupElevatedProcess {
    param(
        [string]$FilePath,
        [string]$ArgumentLine
    )

    return Invoke-360CleanupRuntimeProvider -Name 'StartElevatedProcess' -ArgumentList @($FilePath, $ArgumentLine) -Default {
        param($Executable, $Arguments)
        Start-Process -FilePath $Executable -Verb RunAs -ArgumentList $Arguments -Wait -PassThru
    }
}

function Start-360CleanupVendorUninstaller {
    param(
        [string]$FilePath,
        [string]$ArgumentLine,
        [int]$TimeoutMilliseconds,
        [scriptblock]$OnStarted
    )

    $launchState = [pscustomobject]@{ Started = $false }
    $trackedOnStarted = {
        if (-not $launchState.Started) {
            $launchState.Started = $true
            & $OnStarted
        }
    }.GetNewClosure()

    try {
        $result = Invoke-360CleanupRuntimeProvider -Name 'StartVendorUninstaller' `
            -ArgumentList @($FilePath, $ArgumentLine, $TimeoutMilliseconds, $trackedOnStarted) -Default {
            param($Executable, $Arguments, $Timeout, $ReleaseApprovedFileHandle)

            $process = $null
            try {
                $process = Start-Process -FilePath $Executable -ArgumentList $Arguments `
                    -PassThru -ErrorAction Stop
                if ($null -eq $process) { throw 'Start-Process did not return a process object.' }

                try { & $ReleaseApprovedFileHandle }
                catch {
                    return [pscustomobject]@{
                        Result = 'Pending'
                        ExitCode = $null
                        Detail = 'The vendor uninstaller started, but its launch-boundary callback failed. It was not terminated.'
                    }
                }

                try {
                    if (-not $process.WaitForExit($Timeout)) {
                        return [pscustomobject]@{
                            Result = 'Pending'
                            ExitCode = $null
                            Detail = "The vendor uninstaller did not exit within $Timeout milliseconds. It was not terminated."
                        }
                    }

                    $process.Refresh()
                    $exitCode = [int]$process.ExitCode
                    if ($exitCode -eq 0) {
                        return [pscustomobject]@{
                            Result = 'Success'
                            ExitCode = $exitCode
                            Detail = 'The vendor uninstaller exited successfully.'
                        }
                    }
                    return [pscustomobject]@{
                        Result = 'Failed'
                        ExitCode = $exitCode
                        Detail = "The vendor uninstaller exited with code $exitCode."
                    }
                }
                catch {
                    return [pscustomobject]@{
                        Result = 'Pending'
                        ExitCode = $null
                        Detail = ('The vendor uninstaller started, but its exit could not be proven. It was not terminated. ' + $_.Exception.Message)
                    }
                }
            }
            finally {
                if ($null -ne $process) {
                    try { $process.Dispose() }
                    catch {}
                }
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Result = $(if ($launchState.Started) { 'Pending' } else { 'Failed' })
            ExitCode = $null
            Detail = $(if ($launchState.Started) {
                'The vendor uninstaller started, but its final state is unknown. It was not terminated. ' + $_.Exception.Message
            } else { $_.Exception.Message })
        }
    }

    if ($null -eq $result) {
        return [pscustomobject]@{
            Result = $(if ($launchState.Started) { 'Pending' } else { 'Failed' }); ExitCode = $null
            Detail = 'The vendor-uninstaller provider returned no result.'
        }
    }
    $propertyNames = @($result.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'Result' -or $propertyNames -notcontains 'ExitCode' -or
        $propertyNames -notcontains 'Detail' -or
        [string]$result.Result -notin @('Success', 'Failed', 'Pending')) {
        return [pscustomobject]@{
            Result = $(if ($launchState.Started) { 'Pending' } else { 'Failed' }); ExitCode = $null
            Detail = 'The vendor-uninstaller provider returned an invalid result.'
        }
    }
    if (-not $launchState.Started -and [string]$result.Result -ne 'Failed') {
        return [pscustomobject]@{
            Result = 'Failed'; ExitCode = $null
            Detail = 'The vendor-uninstaller provider did not prove that startup completed at the locked-file boundary.'
        }
    }
    return [pscustomobject]@{
        Result = [string]$result.Result
        ExitCode = $result.ExitCode
        Detail = [string]$result.Detail
    }
}

function Get-360CleanupPathItem {
    param([string]$Path)

    return Invoke-360CleanupRuntimeProvider -Name 'PathItem' -ArgumentList @($Path) -Default {
        param($Target)
        Get-Item -LiteralPath $Target -Force -ErrorAction Stop
    }
}

function Get-360CleanupPathChildren {
    param([string]$Path)

    return @(Invoke-360CleanupRuntimeProvider -Name 'PathChildren' -ArgumentList @($Path) -Default {
        param($Target)
        Get-ChildItem -LiteralPath $Target -Force -ErrorAction Stop
    })
}

function Remove-360CleanupPath {
    param([string]$Path)

    Invoke-360CleanupRuntimeProvider -Name 'RemovePath' -ArgumentList @($Path) -Default {
        param($Target)
        Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction Stop
    } | Out-Null
}

function Repair-360CleanupPathAcl {
    param([string]$Path)

    Invoke-360CleanupRuntimeProvider -Name 'RepairPathAcl' -ArgumentList @($Path) -Default {
        param($Target)

        # This operation is deliberately non-recursive. The caller must re-enumerate the
        # complete removal root before deciding whether recursive deletion is safe.
        & takeown.exe /F $Target 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "takeown.exe failed with exit code $LASTEXITCODE." }
        & icacls.exe $Target /grant '*S-1-5-32-544:F' /C /L 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls.exe failed with exit code $LASTEXITCODE." }
    } | Out-Null
}

function Get-NormalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try {
        $full = [IO.Path]::GetFullPath($expanded)
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
        return $full
    }
    catch {
        return $null
    }
}

function Get-360CleanupStreamSha256 {
    param([IO.Stream]$Stream)

    if ($null -eq $Stream -or -not $Stream.CanRead -or -not $Stream.CanSeek) {
        throw 'A readable, seekable stream is required for SHA-256 verification.'
    }
    $Stream.Position = 0
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Stream))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $Stream.Position = 0
    }
}

function Get-RegistryKeyLeafName {
    param([object]$Key)

    if ($null -eq $Key) { return '' }
    $propertyNames = @($Key.PSObject.Properties.Name)
    if ($propertyNames -contains 'PSChildName' -and
        -not [string]::IsNullOrWhiteSpace([string]$Key.PSChildName)) {
        return [string]$Key.PSChildName
    }
    if ($propertyNames -notcontains 'PSPath') { return '' }
    $match = [regex]::Match([string]$Key.PSPath, '[\\/]([^\\/]+)$')
    if (-not $match.Success) { return '' }
    return [string]$match.Groups[1].Value
}

function Get-DuohuiCleanupPathRoots {
    $roots = New-Object System.Collections.ArrayList
    if ($script:KnownFolders.LocalAppData) {
        [void]$roots.Add((Get-NormalPath (Join-Path $script:KnownFolders.LocalAppData 'dhpingbao')))
    }
    if ($script:KnownFolders.Temp) {
        [void]$roots.Add((Get-NormalPath (Join-Path $script:KnownFolders.Temp 'duohuipingbao')))
        [void]$roots.Add((Get-NormalPath (Join-Path $script:KnownFolders.Temp 'huabao_tmp')))
    }
    return @($roots | Where-Object { $_ })
}

function Test-IsExactDuohuiCleanupPath {
    param([string]$Path)

    $normal = Get-NormalPath $Path
    if (-not $normal) { return $false }
    foreach ($root in @(Get-DuohuiCleanupPathRoots)) {
        if ($normal.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-DuohuiVendorUninstallerPath {
    if (-not $script:KnownFolders.LocalAppData) { return $null }
    return Get-NormalPath (Join-Path $script:KnownFolders.LocalAppData 'dhpingbao\huabaosetup.exe')
}

function Invoke-ApprovedDuohuiVendorUninstaller {
    param([object]$Finding)

    $expectedPath = Get-DuohuiVendorUninstallerPath
    $approvedPath = Get-NormalPath ([string]$Finding.Target)
    $approvedHash = [string]$Finding.ValueName
    if (-not $expectedPath -or -not $approvedPath -or
        -not $approvedPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Result = 'Failed'; ExitCode = $null
            Detail = 'The approved vendor-uninstaller target is not the exact dhpingbao huabaosetup.exe path.'
        }
    }
    if ($approvedHash -notmatch '^[0-9A-F]{64}$') {
        return [pscustomobject]@{
            Result = 'Failed'; ExitCode = $null
            Detail = 'The approved vendor-uninstaller finding does not contain an uppercase SHA-256 identity.'
        }
    }

    $pathState = Get-PathTraversalSafetyState $approvedPath
    if ($pathState.State -ne 'Safe' -or -not $pathState.Exists -or -not $pathState.TreeScanComplete) {
        return [pscustomobject]@{
            Result = 'Failed'; ExitCode = $null
            Detail = 'The exact vendor-uninstaller path chain was not proven safe immediately before launch.'
        }
    }
    $lockState = [pscustomobject]@{
        Stream = $null
        Released = $false
    }
    $releaseFileHandle = {
        if (-not $lockState.Released) {
            if ($null -ne $lockState.Stream) {
                $lockState.Stream.Dispose()
                $lockState.Stream = $null
            }
            $lockState.Released = $true
        }
    }.GetNewClosure()

    try {
        $lockState.Stream = [IO.File]::Open(
            $approvedPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        if (-not (Test-IsTrustedDuohuiVendorFile $approvedPath)) {
            return [pscustomobject]@{
                Result = 'Failed'; ExitCode = $null
                Detail = 'The locked vendor-uninstaller file no longer has the required valid publisher signature and Duohui/Huabao metadata.'
            }
        }
        $actualHash = Get-360CleanupStreamSha256 $lockState.Stream
        if (-not $actualHash.Equals($approvedHash, [StringComparison]::Ordinal)) {
            return [pscustomobject]@{
                Result = 'Failed'; ExitCode = $null
                Detail = 'The vendor uninstaller changed after approval; it was not started.'
            }
        }

        return Start-360CleanupVendorUninstaller -FilePath $approvedPath `
            -ArgumentLine '/uninstall:byUserName' -TimeoutMilliseconds 60000 `
            -OnStarted $releaseFileHandle
    }
    catch {
        return [pscustomobject]@{
            Result = $(if ($lockState.Released) { 'Pending' } else { 'Failed' })
            ExitCode = $null
            Detail = $(if ($lockState.Released) {
                'The vendor uninstaller may have started, but its final state is unknown. It was not terminated. ' + $_.Exception.Message
            } else { $_.Exception.Message })
        }
    }
    finally {
        try { & $releaseFileHandle }
        catch {}
    }
}

function New-CleanupApprovalContext {
    param([bool]$IncludeBrowserProfiles = $false)

    $knownFolders = [ordered]@{}
    foreach ($name in @(
        'LocalAppData', 'RoamingAppData', 'ProgramFiles', 'ProgramFilesX86', 'ProgramData',
        'UserProfile', 'Desktop', 'Temp', 'Windows'
    )) {
        $knownFolders[$name] = $script:KnownFolders[$name]
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -eq $identity.User -or [string]::IsNullOrWhiteSpace($identity.User.Value)) {
        throw 'The current Windows user SID could not be determined for the approval context.'
    }

    return [pscustomobject]@{
        UserSid      = [string]$identity.User.Value
        KnownFolders = [pscustomobject]$knownFolders
        Options      = [pscustomobject]@{
            IncludeBrowserProfiles = [bool]$IncludeBrowserProfiles
        }
    }
}

function Assert-CleanupApprovalContextMatchesCaller {
    param([object]$ApprovalContext)

    if ($null -eq $ApprovalContext) { throw 'ApprovalContext is required.' }
    $propertyNames = @($ApprovalContext.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'UserSid' -or $propertyNames -notcontains 'KnownFolders' -or
        $propertyNames -notcontains 'Options') {
        throw 'ApprovalContext must contain UserSid, KnownFolders, and Options.'
    }
    if ($null -eq $ApprovalContext.KnownFolders -or $null -eq $ApprovalContext.Options -or
        @($ApprovalContext.Options.PSObject.Properties.Name) -notcontains 'IncludeBrowserProfiles' -or
        -not ($ApprovalContext.Options.IncludeBrowserProfiles -is [bool])) {
        throw 'ApprovalContext contains invalid folders or options.'
    }

    $expected = New-CleanupApprovalContext `
        -IncludeBrowserProfiles ([bool]$ApprovalContext.Options.IncludeBrowserProfiles)
    if (-not ([string]$ApprovalContext.UserSid).Equals(
        [string]$expected.UserSid, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The approved Scan report belongs to a different Windows user. Run Scan again as the current user.'
    }

    $folderNames = @(
        'LocalAppData', 'RoamingAppData', 'ProgramFiles', 'ProgramFilesX86', 'ProgramData',
        'UserProfile', 'Desktop', 'Temp', 'Windows'
    )
    $sourceFolderNames = @($ApprovalContext.KnownFolders.PSObject.Properties.Name)
    foreach ($name in $folderNames) {
        if ($sourceFolderNames -notcontains $name) {
            throw "ApprovalContext KnownFolders is missing $name."
        }
        $approvedValue = [string]$ApprovalContext.KnownFolders.$name
        $expectedValue = [string]$expected.KnownFolders.$name
        $approvedPath = Get-NormalPath $approvedValue
        $expectedPath = Get-NormalPath $expectedValue
        $bothEmpty = [string]::IsNullOrWhiteSpace($approvedValue) -and
            [string]::IsNullOrWhiteSpace($expectedValue)
        if (-not $bothEmpty -and (-not $approvedPath -or
            -not $approvedValue.Equals($approvedPath, [StringComparison]::OrdinalIgnoreCase) -or
            -not $expectedPath -or
            -not $approvedPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase))) {
            throw "The approved Scan report $name folder does not match the current caller. Run Scan again."
        }
    }
}

function Read-ApprovedCleanupReport {
    param(
        [string]$Path,
        [string]$ExpectedHash
    )

    $normalPath = Get-NormalPath $Path
    if (-not $normalPath -or [IO.Path]::GetExtension($normalPath) -ne '.json') {
        throw 'ApprovedReport must be a valid .json file path.'
    }
    if (-not (Test-Path -LiteralPath $normalPath -PathType Leaf)) {
        throw "Approved cleanup report was not found: $normalPath"
    }

    try {
        $bytes = [IO.File]::ReadAllBytes($normalPath)
    }
    catch {
        throw "Approved cleanup report could not be read: $normalPath. $($_.Exception.Message)"
    }

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
        if ($ExpectedHash -notmatch '^[0-9a-fA-F]{64}$' -or
            -not $hash.Equals($ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Approved cleanup report hash does not match the hash accepted before elevation.'
        }
    }

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $json = $utf8.GetString($bytes)
        $report = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Approved cleanup report is not valid UTF-8 JSON: $normalPath. $($_.Exception.Message)"
    }

    $propertyNames = @($report.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'SchemaVersion' -or [int]$report.SchemaVersion -ne 2) {
        throw 'Approved cleanup report must use SchemaVersion 2.'
    }
    if ($propertyNames -notcontains 'Mode' -or [string]$report.Mode -cne 'Scan') {
        throw 'Approved cleanup report must have Mode set to Scan.'
    }
    if ($propertyNames -notcontains 'ApprovalContext' -or $null -eq $report.ApprovalContext) {
        throw 'Approved cleanup report is missing ApprovalContext.'
    }
    if ($propertyNames -notcontains 'Findings' -or $null -eq $report.Findings) {
        throw 'Approved cleanup report is missing Findings.'
    }

    return [pscustomobject]@{
        Path   = $normalPath
        Hash   = $hash
        Report = $report
    }
}

function Set-CleanupSourceContext {
    param([object]$ApprovalContext)

    if ($null -eq $ApprovalContext) { throw 'ApprovalContext is required.' }
    $propertyNames = @($ApprovalContext.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'UserSid' -or $propertyNames -notcontains 'KnownFolders' -or
        $propertyNames -notcontains 'Options') {
        throw 'ApprovalContext must contain UserSid, KnownFolders, and Options.'
    }

    $userSid = [string]$ApprovalContext.UserSid
    if ($userSid -notmatch '^S-\d+(?:-\d+)+$') {
        throw 'ApprovalContext contains an invalid Windows user SID.'
    }
    $registryRoot = 'Registry::HKEY_USERS\' + $userSid
    if (-not (Test-360CleanupRegistryPath $registryRoot)) {
        throw "The approved user's registry hive is not loaded: $registryRoot"
    }

    $folderNames = @(
        'LocalAppData', 'RoamingAppData', 'ProgramFiles', 'ProgramFilesX86', 'ProgramData',
        'UserProfile', 'Desktop', 'Temp', 'Windows'
    )
    $sourceFolderNames = @($ApprovalContext.KnownFolders.PSObject.Properties.Name)
    $knownFolders = [ordered]@{}
    foreach ($name in $folderNames) {
        if ($sourceFolderNames -notcontains $name) {
            throw "ApprovalContext KnownFolders is missing $name."
        }
        $value = [string]$ApprovalContext.KnownFolders.$name
        if ([string]::IsNullOrWhiteSpace($value)) {
            $knownFolders[$name] = ''
            continue
        }
        $normalValue = Get-NormalPath $value
        if (-not $normalValue -or
            -not $value.Equals($normalValue, [StringComparison]::OrdinalIgnoreCase)) {
            throw "ApprovalContext KnownFolders $name must be a normalized absolute literal path."
        }
        $knownFolders[$name] = $normalValue
    }
    foreach ($name in @('LocalAppData', 'RoamingAppData', 'ProgramFiles', 'ProgramData', 'UserProfile', 'Temp', 'Windows')) {
        if ([string]::IsNullOrWhiteSpace([string]($knownFolders[$name]))) {
            throw "ApprovalContext KnownFolders contains an empty required $name path."
        }
    }
    foreach ($name in @('ProgramFiles', 'ProgramFilesX86', 'ProgramData', 'Windows')) {
        $hostValue = [string]($script:KnownFolders[$name])
        $approvedValue = [string]($knownFolders[$name])
        $bothEmpty = [string]::IsNullOrWhiteSpace($hostValue) -and [string]::IsNullOrWhiteSpace($approvedValue)
        $hostPath = Get-NormalPath $hostValue
        if (-not $bothEmpty -and (-not $hostPath -or -not $approvedValue.Equals(
            $hostPath, [StringComparison]::OrdinalIgnoreCase))) {
            throw "ApprovalContext $name does not match this Windows installation."
        }
    }
    if (@($ApprovalContext.Options.PSObject.Properties.Name) -notcontains 'IncludeBrowserProfiles') {
        throw 'ApprovalContext Options is missing IncludeBrowserProfiles.'
    }
    if (-not ($ApprovalContext.Options.IncludeBrowserProfiles -is [bool])) {
        throw 'ApprovalContext IncludeBrowserProfiles must be a Boolean value.'
    }

    $script:KnownFolders = $knownFolders
    $script:CurrentUserRegistryRoot = $registryRoot
}

function Get-FindingResourceKey {
    param(
        [object]$Finding,
        [string]$UserSid
    )

    if ($null -eq $Finding) { throw 'Finding is required.' }
    $kind = [string]$Finding.Kind
    $target = [string]$Finding.Target
    $valueName = [string]$Finding.ValueName
    if ($kind -eq 'Process') {
        $target = $valueName
        $valueName = ''
    }

    if (-not [string]::IsNullOrWhiteSpace($UserSid)) {
        if ($UserSid -notmatch '^S-\d+(?:-\d+)+$') { throw 'UserSid is not a valid Windows SID.' }
        $escapedSid = [regex]::Escape($UserSid)
        $userPrefixes = @(
            '^HKCU:\\',
            '^(?:Microsoft\.PowerShell\.Core\\)?Registry::HKEY_CURRENT_USER\\',
            ('^(?:Microsoft\.PowerShell\.Core\\)?Registry::HKEY_USERS\\' + $escapedSid + '\\')
        )
        foreach ($prefix in $userPrefixes) {
            $match = [regex]::Match($target, $prefix, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $target = 'USER:\' + $target.Substring($match.Length)
                break
            }
        }
    }

    if ($kind -in @('Path', 'OfflinePath', 'Process', 'VendorUninstaller')) {
        $normalTarget = Get-NormalPath $target
        if ($normalTarget) { $target = $normalTarget }
    }
    $separator = [string][char]31
    return (($kind, $target, $valueName) -join $separator).ToUpperInvariant()
}

function Get-FindingApprovalKey {
    param(
        [object]$Finding,
        [string]$UserSid
    )

    $separator = [string][char]31
    $resourceKey = Get-FindingResourceKey -Finding $Finding -UserSid $UserSid
    $removalType = [string]$Finding.RemovalType
    $identityFingerprint = [string](Get-PropertyValue $Finding 'IdentityFingerprint')
    if ($removalType -in @('Service', 'Task', 'RegistryValue', 'RegistryKey') -and
        $identityFingerprint -notmatch '^[0-9A-F]{64}$') {
        throw "Confirmed $removalType finding is missing its uppercase identity fingerprint."
    }
    return (($resourceKey, $removalType, $identityFingerprint) -join $separator).ToUpperInvariant()
}

function Compare-ApprovedCleanupFindings {
    param(
        [object[]]$Approved,
        [object[]]$Current,
        [string]$SID
    )

    $approvedByKey = @{}
    foreach ($finding in @($Approved | Where-Object {
        $_.Confidence -eq 'Confirmed' -and -not $_.Offline -and $_.RemovalType -ne 'None'
    })) {
        $key = Get-FindingApprovalKey -Finding $finding -UserSid $SID
        if (-not $approvedByKey.ContainsKey($key)) { $approvedByKey[$key] = $finding }
    }

    $currentByResourceKey = @{}
    foreach ($finding in @($Current)) {
        $resourceKey = Get-FindingResourceKey -Finding $finding -UserSid $SID
        if (-not $currentByResourceKey.ContainsKey($resourceKey)) {
            $currentByResourceKey[$resourceKey] = New-Object System.Collections.ArrayList
        }
        [void]$currentByResourceKey[$resourceKey].Add($finding)
    }

    $eligible = New-Object System.Collections.ArrayList
    $newSinceApproval = New-Object System.Collections.ArrayList
    foreach ($finding in @($Current | Where-Object {
        $_.Confidence -eq 'Confirmed' -and -not $_.Offline -and $_.RemovalType -ne 'None'
    })) {
        $key = Get-FindingApprovalKey -Finding $finding -UserSid $SID
        if ($approvedByKey.ContainsKey($key)) {
            [void]$eligible.Add($finding)
        }
        else { [void]$newSinceApproval.Add($finding) }
    }

    $missingSinceApproval = New-Object System.Collections.ArrayList
    $noLongerConfirmed = New-Object System.Collections.ArrayList
    foreach ($key in @($approvedByKey.Keys)) {
        $approvedFinding = $approvedByKey[$key]
        $resourceKey = Get-FindingResourceKey -Finding $approvedFinding -UserSid $SID
        if (-not $currentByResourceKey.ContainsKey($resourceKey)) {
            [void]$missingSinceApproval.Add($approvedByKey[$key])
            continue
        }
        $stillConfirmed = @($currentByResourceKey[$resourceKey] | Where-Object {
            $_.Confidence -eq 'Confirmed' -and -not $_.Offline -and
                (Get-FindingApprovalKey -Finding $_ -UserSid $SID) -eq $key
        }).Count -gt 0
        if (-not $stillConfirmed) { [void]$noLongerConfirmed.Add($approvedByKey[$key]) }
    }

    return [pscustomobject]@{
        Eligible             = @($eligible)
        NewSinceApproval     = @($newSinceApproval)
        MissingSinceApproval = @($missingSinceApproval)
        NoLongerConfirmed    = @($noLongerConfirmed)
        ApprovedCount        = $approvedByKey.Count
    }
}

function ConvertTo-CleanupQuotedArgument {
    param([string]$Value)

    if ($Value -match '[\r\n"]') { throw 'A cleanup command-line path contains unsupported quote or newline characters.' }
    return '"' + $Value + '"'
}

function New-ElevatedCleanupArgumentLine {
    param(
        [string]$ScriptPath,
        [string]$ApprovedReport,
        [string]$ApprovedReportHash,
        [string]$OutcomeRunId,
        [string]$ReportPath,
        [bool]$IncludeBrowserProfiles = $false,
        [bool]$AllowExplorerRestart = $false,
        [bool]$ForceLockedTargets = $false,
        [bool]$IncludeIdentityInReport = $false
    )

    if ($ApprovedReportHash -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'ApprovedReportHash must be a SHA-256 hash.'
    }
    if ($OutcomeRunId -notmatch '^[0-9a-fA-F]{32}$') {
        throw 'OutcomeRunId must be a 32-character run identifier.'
    }
    $argumentParts = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CleanupQuotedArgument $ScriptPath),
        '-Mode', 'Remove', '-ConfirmRemoval', '-ConfirmationPhrase', 'REMOVE-CONFIRMED-360',
        '-ApprovedReport', (ConvertTo-CleanupQuotedArgument $ApprovedReport),
        '-ApprovedReportHash', $ApprovedReportHash,
        '-OutcomeRunId', $OutcomeRunId,
        '-InternalElevatedChild',
        '-ReportPath', (ConvertTo-CleanupQuotedArgument $ReportPath)
    )
    if ($IncludeBrowserProfiles) {
        $argumentParts += @('-IncludeBrowserProfiles', '-BrowserProfileConfirmation', 'DELETE-360-BROWSER-DATA')
    }
    if ($AllowExplorerRestart) { $argumentParts += '-AllowExplorerRestart' }
    if ($ForceLockedTargets) { $argumentParts += '-ForceLockedTargets' }
    if ($IncludeIdentityInReport) { $argumentParts += '-IncludeIdentityInReport' }
    return $argumentParts -join ' '
}

function Test-IsUnderPath {
    param(
        [string]$Candidate,
        [string]$Root
    )

    $candidatePath = Get-NormalPath $Candidate
    $rootPath = Get-NormalPath $Root
    if (-not $candidatePath -or -not $rootPath) { return $false }

    return $candidatePath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
        $candidatePath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-CommandExecutableToken {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($expanded.StartsWith('"')) {
        $end = $expanded.IndexOf('"', 1)
        if ($end -gt 1) { return $expanded.Substring(1, $end - 1) }
    }

    $match = [regex]::Match($expanded, '^(.*?\.(?:exe|com|bat|cmd|scr|dll|sys))(?=\s|$)', 'IgnoreCase')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-CommandExecutable {
    param([string]$CommandLine)

    $executable = Get-CommandExecutableToken $CommandLine
    if (-not $executable) { return $null }
    return Get-NormalPath $executable
}

function Get-FileReferenceState {
    param(
        [string]$Value,
        [switch]$CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Absent' }
    $target = if ($CommandLine) { Get-CommandExecutableToken $Value } else { $Value }
    if ([string]::IsNullOrWhiteSpace($target)) { return 'Unknown' }
    if (-not [IO.Path]::IsPathRooted($target)) { return 'Unknown' }
    $normalized = Get-NormalPath $target
    if (-not $normalized) { return 'Unknown' }
    try {
        if (Test-Path -LiteralPath $normalized -ErrorAction Stop) { return 'Live' }
        if ($normalized.StartsWith('\\')) { return 'Unknown' }
        $pathRoot = [IO.Path]::GetPathRoot($normalized)
        if ([string]::IsNullOrWhiteSpace($pathRoot) -or
            -not (Test-Path -LiteralPath $pathRoot -ErrorAction Stop)) { return 'Unknown' }
        return 'Stale'
    }
    catch {
        return 'Unknown'
    }
}

function Get-DisplayIconReferenceState {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Absent' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Value.Trim())
    if ($expanded.StartsWith('"')) {
        $end = $expanded.IndexOf('"', 1)
        if ($end -le 1) { return 'Unknown' }
        $target = $expanded.Substring(1, $end - 1)
    }
    else {
        $target = [regex]::Replace($expanded, ',\s*-?\d+\s*$', '').Trim()
    }
    return Get-FileReferenceState $target
}

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SignerSubject {
    param([string]$Path)

    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate) {
            return [string]$signature.SignerCertificate.Subject
        }
    }
    catch {}
    return ''
}

function Test-Is360File {
    param([string]$Path)

    return [bool](Invoke-360CleanupRuntimeProvider -Name 'Is360File' -ArgumentList @($Path) -Default {
        param($CandidatePath)

        if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) { return $false }
        try {
            $item = Get-Item -LiteralPath $CandidatePath -Force
            $version = $item.VersionInfo
            $metadata = '{0} {1} {2} {3}' -f $version.CompanyName, $version.ProductName, $version.FileDescription, $version.OriginalFilename
            $signer = Get-SignerSubject $CandidatePath
            return ($metadata -match '(?i)360\.cn|Qihoo|Qihu|奇虎|360安全|360软件管家|多绘屏保') -or
                ($signer -match '(?i)Beijing Qihu Technology|Qihoo|奇虎')
        }
        catch {
            return $false
        }
    })
}

function Test-IsDuohuiFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $version = (Get-Item -LiteralPath $Path -Force).VersionInfo
        $metadata = '{0} {1} {2} {3}' -f $version.CompanyName, $version.ProductName, $version.FileDescription, $version.OriginalFilename
        return (Test-Is360File $Path) -or ($metadata -match '(?i)多绘|画报|duohui|huabao')
    }
    catch { return $false }
}

function Test-IsTrustedDuohuiVendorFile {
    param([string]$Path)

    return [bool](Invoke-360CleanupRuntimeProvider -Name 'IsTrustedDuohuiVendorFile' `
        -ArgumentList @($Path) -Default {
        param($CandidatePath)

        if (-not (Test-Path -LiteralPath $CandidatePath -PathType Leaf)) { return $false }
        try {
            $signature = Get-AuthenticodeSignature -LiteralPath $CandidatePath -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
                return $false
            }
            $simpleName = $signature.SignerCertificate.GetNameInfo(
                [Security.Cryptography.X509Certificates.X509NameType]::SimpleName,
                $false
            )
            if (-not [string]$simpleName -or
                -not ([string]$simpleName).Equals(
                    'Beijing Qihu Technology Co., Ltd.',
                    [StringComparison]::Ordinal
                )) {
                return $false
            }

            $version = (Get-Item -LiteralPath $CandidatePath -Force -ErrorAction Stop).VersionInfo
            $metadata = '{0} {1} {2} {3}' -f $version.CompanyName, $version.ProductName, `
                $version.FileDescription, $version.OriginalFilename
            return $metadata -match '(?i)多绘|画报|duohui|huabao'
        }
        catch { return $false }
    })
}

function Test-DirectoryHas360File {
    param(
        [string]$Path,
        [int]$MaximumFiles = 4096
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $checked = 0
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $Path -File -Force -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.Extension -notmatch '(?i)^\.(exe|dll|scr|sys)$') { continue }
            $checked++
            if (Test-Is360File $file.FullName) { return $true }
            if ($checked -ge $MaximumFiles) { break }
        }
    }
    catch {}
    return $false
}

function Test-DuohuiEvidence {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $markers = @(
        'duohuipingbao.exe', 'huabaosetup.exe', '360hb_tmp',
        'qcnethelp64.dll', 'xhqcnethelp64.dll'
    )
    $markerHits = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue)) {
        if ($markers -contains $item.Name) { [void]$markerHits.Add($item.Name) }
        if (-not $item.PSIsContainer -and $item.Name -match '(?i)^(duohuipingbao|huabaosetup)\.exe$' -and
            (Test-IsDuohuiFile $item.FullName)) { return $true }
    }
    return $markerHits.Count -ge 2
}

function Test-SoftMgrEvidence {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $executables = @(Get-ChildItem -LiteralPath $Path -Filter 'softmgrsvr.exe' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($file in $executables) {
        if (Test-Is360File $file.FullName) { return $true }
    }

    foreach ($name in @('360Base.dll', '360Conf.dll', '360NetBase.dll', '360Util.dll')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter $name -File -Recurse -ErrorAction SilentlyContinue)) {
            if (Test-Is360File $file.FullName) { return $true }
        }
    }
    return $false
}

function Test-GreenCoreEvidence {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $Path -Filter '360greencore.exe' -File -Recurse -ErrorAction SilentlyContinue)) {
        if (Test-Is360File $file.FullName) { return $true }
    }
    return $false
}

function New-Finding {
    param(
        [string]$Kind,
        [string]$Name,
        [string]$Target,
        [ValidateSet('Confirmed', 'ReviewOnly')]
        [string]$Confidence,
        [string]$Reason,
        [ValidateSet('Path', 'RegistryKey', 'RegistryValue', 'Service', 'Task', 'Process', 'VendorUninstaller', 'None')]
        [string]$RemovalType = 'None',
        [string]$ValueName = '',
        [string]$IdentityFingerprint = '',
        [bool]$Offline = $false
    )

    [pscustomobject]@{
        Kind        = $Kind
        Name        = $Name
        Target      = $Target
        Confidence  = $Confidence
        Reason      = $Reason
        RemovalType = $RemovalType
        ValueName   = $ValueName
        IdentityFingerprint = $IdentityFingerprint
        Offline     = $Offline
    }
}

function Add-Finding {
    param(
        [System.Collections.IList]$List,
        [object]$Finding
    )

    $duplicate = @($List | Where-Object {
        $_.Kind -eq $Finding.Kind -and $_.Target -eq $Finding.Target -and $_.ValueName -eq $Finding.ValueName
    }).Count -gt 0
    if (-not $duplicate) { [void]$List.Add($Finding) }
}

function Get-ConfirmedPathRoots {
    param([object[]]$Findings)
    return @($Findings | Where-Object {
        $_.Confidence -eq 'Confirmed' -and $_.RemovalType -eq 'Path'
    } | ForEach-Object { $_.Target } | Sort-Object -Unique)
}

function Get-360Findings {
    param(
        [string]$OfflineRoot,
        [bool]$IncludeProfiles = $false
    )

    $findings = New-Object System.Collections.ArrayList
    $localAppData = $script:KnownFolders.LocalAppData
    $roamingAppData = $script:KnownFolders.RoamingAppData
    $programFiles = $script:KnownFolders.ProgramFiles
    $programFilesX86 = $script:KnownFolders.ProgramFilesX86
    $programData = $script:KnownFolders.ProgramData
    $tempRoot = $script:KnownFolders.Temp
    $currentUserRegistryRoot = $script:CurrentUserRegistryRoot.TrimEnd('\')

    $machineInstallEvidence = $false
    foreach ($root in @(
        $(if ($programFiles) { Join-Path $programFiles '360' }),
        $(if ($programFilesX86) { Join-Path $programFilesX86 '360' })
    ) | Where-Object { $_ }) {
        if (Test-DirectoryHas360File $root) { $machineInstallEvidence = $true; break }
    }

    $exactPaths = @()
    if ($programFiles) { $exactPaths += @{ Name = '360 Program Files'; Path = (Join-Path $programFiles '360'); Confirm = 'Product'; Reason = 'Exact vendor product directory with local 360/Qihoo file evidence.' } }
    if ($programFilesX86) { $exactPaths += @{ Name = '360 Program Files (x86)'; Path = (Join-Path $programFilesX86 '360'); Confirm = 'Product'; Reason = 'Exact vendor product directory with local 360/Qihoo file evidence.' } }
    if ($programData) {
        $exactPaths += @{ Name = '360 ProgramData'; Path = (Join-Path $programData '360'); Confirm = 'MachineData'; Reason = 'Exact vendor data directory paired with local 360/Qihoo file evidence.' }
        $exactPaths += @{ Name = '360Safe ProgramData'; Path = (Join-Path $programData '360safe'); Confirm = 'MachineData'; Reason = 'Exact 360Safe data directory paired with local 360/Qihoo file evidence.' }
    }
    if ($localAppData) {
        $exactPaths += @{ Name = '360Chrome browser application'; Path = (Join-Path $localAppData '360Chrome\Chrome\Application'); Confirm = 'Product'; Reason = 'Exact 360Chrome Application directory with local 360/Qihoo file evidence.' }
        $exactPaths += @{ Name = '360Chrome browser profile'; Path = (Join-Path $localAppData '360Chrome\Chrome\User Data'); Confirm = 'BrowserProfile'; Reason = '360Chrome User Data can contain bookmarks, history, saved sessions, and other user data.' }
        $exactPaths += @{ Name = '360ChromeX browser application'; Path = (Join-Path $localAppData '360ChromeX\Chrome\Application'); Confirm = 'Product'; Reason = 'Exact 360ChromeX Application directory with local 360/Qihoo file evidence.' }
        $exactPaths += @{ Name = '360ChromeX browser profile'; Path = (Join-Path $localAppData '360ChromeX\Chrome\User Data'); Confirm = 'BrowserProfile'; Reason = '360ChromeX User Data can contain bookmarks, history, saved sessions, and other user data.' }
        $exactPaths += @{ Name = 'Duohui screen saver'; Path = (Join-Path $localAppData 'dhpingbao'); Confirm = 'Duohui'; Reason = 'Known duohuipingbao installation path.' }
    }
    if ($roamingAppData) {
        $exactPaths += @{ Name = '360se6 browser application'; Path = (Join-Path $roamingAppData '360se6\Application'); Confirm = 'Product'; Reason = 'Exact 360se6 Application directory with local 360/Qihoo file evidence.' }
        $exactPaths += @{ Name = '360se6 browser profile'; Path = (Join-Path $roamingAppData '360se6\User Data'); Confirm = 'BrowserProfile'; Reason = '360se6 User Data can contain bookmarks, history, saved sessions, and other user data.' }
        $exactPaths += @{ Name = '360browser legacy profile'; Path = (Join-Path $roamingAppData '360browser'); Confirm = 'BrowserProfile'; Reason = 'Legacy browser profiles can contain bookmarks, history, saved sessions, and other user data.' }
        $exactPaths += @{ Name = '360 Software Manager UI kernel'; Path = (Join-Path $roamingAppData 'secoresdk\360se6'); Confirm = 'Product'; Reason = 'Exact secoresdk 360se6 product directory with local 360/Qihoo file evidence.' }
        foreach ($name in @('360Safe', '360GameAssistant', '360huabao', '360DrvMgrScrSaver')) {
            $exactPaths += @{ Name = $name; Path = (Join-Path $roamingAppData $name); Confirm = 'Product'; Reason = 'Exact current-user path with local 360/Qihoo file evidence.' }
        }
        $exactPaths += @{ Name = 'GreenCore'; Path = (Join-Path $roamingAppData 'greencore'); Confirm = 'GreenCore'; Reason = 'GreenCore cache requires a 360greencore marker.' }
        $exactPaths += @{ Name = 'GreenCore7z'; Path = (Join-Path $roamingAppData 'GreenCore7z'); Confirm = 'GreenCore'; Reason = 'GreenCore archive cache requires a 360 marker.' }
    }
    if ($tempRoot) {
        $exactPaths += @{ Name = 'Duohui temporary package'; Path = (Join-Path $tempRoot 'duohuipingbao'); Confirm = 'Duohui'; Reason = 'Known duohuipingbao staging path.' }
        $exactPaths += @{ Name = 'Huabao temporary package'; Path = (Join-Path $tempRoot 'huabao_tmp'); Confirm = 'Duohui'; Reason = 'Known Huabao installer staging path.' }
        $exactPaths += @{ Name = '360 Game Assistant temporary files'; Path = (Join-Path $tempRoot '360gameassistantYyb'); Confirm = 'Product'; Reason = 'Exact temporary component path with local 360/Qihoo file evidence.' }
        $exactPaths += @{ Name = '360 unpack temporary files'; Path = (Join-Path $tempRoot '360UnPackTmp64'); Confirm = 'Product'; Reason = 'Exact temporary component path with local 360/Qihoo file evidence.' }
    }

    foreach ($candidate in $exactPaths) {
        if (-not (Test-Path -LiteralPath $candidate.Path)) { continue }
        $confirmed = $false
        if ($candidate.Confirm -eq 'Product') { $confirmed = Test-DirectoryHas360File $candidate.Path }
        if ($candidate.Confirm -eq 'MachineData') { $confirmed = $machineInstallEvidence -or (Test-DirectoryHas360File $candidate.Path) }
        if ($candidate.Confirm -eq 'Duohui') { $confirmed = Test-DuohuiEvidence $candidate.Path }
        if ($candidate.Confirm -eq 'GreenCore') { $confirmed = Test-GreenCoreEvidence $candidate.Path }
        if ($candidate.Confirm -eq 'BrowserProfile') { $confirmed = $IncludeProfiles }
        $notConfirmedReason = if ($candidate.Confirm -eq 'BrowserProfile') {
            $candidate.Reason + ' Preserved by default; use the separate browser-profile opt-in only after backing up needed data.'
        }
        else { $candidate.Reason + ' Expected product evidence was not found.' }
        Add-Finding $findings (New-Finding -Kind 'Path' -Name $candidate.Name -Target (Get-NormalPath $candidate.Path) `
            -Confidence $(if ($confirmed) { 'Confirmed' } else { 'ReviewOnly' }) `
            -Reason $(if ($confirmed) { $candidate.Reason } else { $notConfirmedReason }) `
            -RemovalType $(if ($confirmed) { 'Path' } else { 'None' }))
    }

    $duohuiInstallRoot = if ($localAppData) {
        Get-NormalPath (Join-Path $localAppData 'dhpingbao')
    }
    else { $null }
    $duohuiVendorPath = Get-DuohuiVendorUninstallerPath
    if ($duohuiVendorPath -and (Test-Path -LiteralPath $duohuiVendorPath -PathType Leaf)) {
        $vendorHash = ''
        $hashError = ''
        $vendorPathState = Get-PathTraversalSafetyState $duohuiVendorPath
        $vendorPathSafe = $vendorPathState.State -eq 'Safe' -and $vendorPathState.Exists -and
            $vendorPathState.TreeScanComplete
        $trustedVendorFile = $false
        if (-not $vendorPathSafe) {
            $hashError = 'The exact uninstaller path chain was not proven safe.'
        }
        else {
            $identityStream = $null
            try {
                $identityStream = [IO.File]::Open(
                    $duohuiVendorPath,
                    [IO.FileMode]::Open,
                    [IO.FileAccess]::Read,
                    [IO.FileShare]::Read
                )
                $trustedVendorFile = Test-IsTrustedDuohuiVendorFile $duohuiVendorPath
                if ($trustedVendorFile) {
                    $vendorHash = Get-360CleanupStreamSha256 $identityStream
                }
            }
            catch { $hashError = $_.Exception.Message }
            finally {
                if ($null -ne $identityStream) { $identityStream.Dispose() }
            }
        }
        $pairedRootConfirmed = @($findings | Where-Object {
            $_.Confidence -eq 'Confirmed' -and $_.RemovalType -eq 'Path' -and
            (Get-NormalPath ([string]$_.Target)) -and
            (Get-NormalPath ([string]$_.Target)).Equals($duohuiInstallRoot, [StringComparison]::OrdinalIgnoreCase)
        }).Count -eq 1
        $vendorConfirmed = $vendorPathSafe -and $pairedRootConfirmed -and $trustedVendorFile -and
            $vendorHash -match '^[0-9A-F]{64}$'
        $vendorReason = if ($vendorConfirmed) {
            'Exact Duohui uninstaller under a confirmed dhpingbao root with a valid Beijing Qihu Technology Co., Ltd. signature and Duohui/Huabao metadata. SHA-256: ' + $vendorHash
        }
        elseif ($hashError) {
            'The exact Duohui uninstaller path exists, but its SHA-256 identity could not be read safely. ' + $hashError
        }
        else {
            'The exact Duohui uninstaller path exists, but it lacks a confirmed dhpingbao root, the required valid publisher signature and Duohui/Huabao metadata, or a valid SHA-256 identity.'
        }
        Add-Finding $findings (New-Finding -Kind 'VendorUninstaller' -Name 'Duohui vendor uninstaller' `
            -Target $duohuiVendorPath -Confidence $(if ($vendorConfirmed) { 'Confirmed' } else { 'ReviewOnly' }) `
            -Reason $vendorReason -RemovalType $(if ($vendorConfirmed) { 'VendorUninstaller' } else { 'None' }) `
            -ValueName $vendorHash)
    }

    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        $tempFiles = @()
        $tempFiles += @(Get-ChildItem -LiteralPath $tempRoot -File -Filter '360greencore.cab' -ErrorAction SilentlyContinue)
        $tempFiles += @(Get-ChildItem -LiteralPath $tempRoot -File -Filter '360se*.cab' -ErrorAction SilentlyContinue)
        foreach ($file in $tempFiles | Sort-Object FullName -Unique) {
            Add-Finding $findings (New-Finding -Kind 'Path' -Name '360 temporary package' -Target $file.FullName `
                -Confidence 'ReviewOnly' -Reason 'Filename pattern matched, but a CAB name alone is not enough evidence for automatic deletion.')
        }
    }

    $toolboxRoot = if ($localAppData) { Join-Path $localAppData 'winToolBox' } else { $null }
    $toolboxConfirmed = $false
    $softMgrConfirmed = $false
    $softMgrRoots = @()
    if ($toolboxRoot -and (Test-Path -LiteralPath (Join-Path $toolboxRoot 'Tools'))) {
        $softMgrRoots = @(Get-ChildItem -LiteralPath (Join-Path $toolboxRoot 'Tools') -Directory -Filter 'SoftMgr*' -ErrorAction SilentlyContinue)
        foreach ($softMgr in $softMgrRoots) {
            if (Test-SoftMgrEvidence $softMgr.FullName) {
                $toolboxConfirmed = $true
                $softMgrConfirmed = $true
                Add-Finding $findings (New-Finding -Kind 'Path' -Name '360 SoftMgr inside Aolande/Huajun winToolBox' `
                    -Target $softMgr.FullName -Confidence 'Confirmed' `
                    -Reason 'SoftMgr subtree contains 360-signed or 360-identified executable/DLL evidence; winToolBox itself is third-party.' `
                    -RemovalType 'Path')
            }
            else {
                Add-Finding $findings (New-Finding -Kind 'Path' -Name 'Ambiguous SoftMgr inside winToolBox' `
                    -Target $softMgr.FullName -Confidence 'ReviewOnly' `
                    -Reason 'Name matched SoftMgr but deterministic 360 markers were not found.')
            }
        }

        $root360Files = @(Get-ChildItem -LiteralPath $toolboxRoot -File -Force -ErrorAction SilentlyContinue | Where-Object { Test-Is360File $_.FullName })
        foreach ($file in $root360Files) {
            $toolboxConfirmed = $true
            Add-Finding $findings (New-Finding -Kind 'Path' -Name '360-signed component inside third-party winToolBox' `
                -Target $file.FullName -Confidence 'Confirmed' `
                -Reason ('File is signed or identified as a 360/Qihoo component. Signer: ' + (Get-SignerSubject $file.FullName)) `
                -RemovalType 'Path')
        }

        if ($toolboxConfirmed) {
            Add-Finding $findings (New-Finding -Kind 'Bundle' -Name 'Aolande/Huajun winToolBox mixed bundle' `
                -Target $toolboxRoot -Confidence 'ReviewOnly' `
                -Reason 'Third-party toolbox contains confirmed 360 components. Do not remove the entire toolbox without separate approval.')
            $updater = Join-Path $toolboxRoot 'winToolBoxSrv.exe'
            if ($softMgrConfirmed -and (Test-Path -LiteralPath $updater -PathType Leaf)) {
                Add-Finding $findings (New-Finding -Kind 'Path' -Name 'winToolBox updater linked to confirmed SoftMgr bundle' `
                    -Target $updater -Confidence 'Confirmed' `
                    -Reason 'Exact third-party updater associated with a locally confirmed 360 SoftMgr/download chain.' `
                    -RemovalType 'Path')
            }
        }
    }

    if ($roamingAppData) {
        $roamingSoftMgr = @(Get-ChildItem -LiteralPath $roamingAppData -Directory -Filter 'SoftMgr*' -ErrorAction SilentlyContinue)
        foreach ($directory in $roamingSoftMgr) {
            $confirmed = Test-SoftMgrEvidence $directory.FullName
            Add-Finding $findings (New-Finding -Kind 'Path' -Name 'Roaming SoftMgr cache' -Target $directory.FullName `
                -Confidence $(if ($confirmed) { 'Confirmed' } else { 'ReviewOnly' }) `
                -Reason $(if ($confirmed) { 'Paired with confirmed 360 SoftMgr evidence.' } else { 'SoftMgr name without enough local 360 evidence.' }) `
                -RemovalType $(if ($confirmed) { 'Path' } else { 'None' }))
        }
    }

    if ($programFiles) {
        $machineSoftMgr = Join-Path $programFiles 'softmgr'
        if (Test-Path -LiteralPath $machineSoftMgr) {
            $confirmed = Test-SoftMgrEvidence $machineSoftMgr
            Add-Finding $findings (New-Finding -Kind 'Path' -Name 'Program Files SoftMgr' -Target $machineSoftMgr `
                -Confidence $(if ($confirmed) { 'Confirmed' } else { 'ReviewOnly' }) `
                -Reason $(if ($confirmed) { '360 product metadata or DLL markers found.' } else { 'Ambiguous SoftMgr directory without sufficient markers.' }) `
                -RemovalType $(if ($confirmed) { 'Path' } else { 'None' }))
        }
    }

    $currentUserUninstallRoot = $currentUserRegistryRoot + '\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    $duohuiOrphanedRecord = $false
    $uninstallRoots = @(
        $currentUserUninstallRoot,
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-360CleanupRegistryPath $root)) { continue }
        foreach ($key in @(Get-360CleanupRegistrySubKeys $root)) {
            $properties = Get-360CleanupRegistryValues $key.PSPath
            $displayName = [string](Get-PropertyValue $properties 'DisplayName')
            $publisher = [string](Get-PropertyValue $properties 'Publisher')
            $isExactDuohuiRecord = $root.Equals($currentUserUninstallRoot, [StringComparison]::OrdinalIgnoreCase) -and
                (Get-RegistryKeyLeafName $key).Equals('duohuipingbao', [StringComparison]::OrdinalIgnoreCase) -and
                $displayName.Equals('duohuipingbao', [StringComparison]::OrdinalIgnoreCase) -and
                $publisher.Equals('duohuipingbao', [StringComparison]::OrdinalIgnoreCase)
            $knownProductName = $displayName -match '(?i)^(360安全卫士|360 Total Security|360杀毒|360安全浏览器|360se|360极速浏览器|360ChromeX|360Chrome|360软件管家|360压缩|360驱动大师|360游戏大厅|360桌面助手|360壁纸|360画报|多绘屏保)(\s|$|[0-9])'
            $knownPublisher = $publisher -match '(?i)360\.cn|360安全中心|Qihoo|Qihu|奇虎'
            if (-not ($isExactDuohuiRecord -or $knownProductName -or $knownPublisher)) { continue }

            $locationState = Get-FileReferenceState ([string](Get-PropertyValue $properties 'InstallLocation'))
            $uninstallState = Get-FileReferenceState `
                -Value ([string](Get-PropertyValue $properties 'UninstallString')) -CommandLine
            $quietUninstallState = Get-FileReferenceState `
                -Value ([string](Get-PropertyValue $properties 'QuietUninstallString')) -CommandLine
            $displayIconState = Get-DisplayIconReferenceState `
                ([string](Get-PropertyValue $properties 'DisplayIcon'))
            $referenceStates = @($locationState, $uninstallState, $quietUninstallState)
            $hasStaleReference = @($referenceStates | Where-Object { $_ -eq 'Stale' }).Count -gt 0
            $hasBlockingReference = @($referenceStates | Where-Object { $_ -in @('Live', 'Unknown') }).Count -gt 0 -or
                $displayIconState -in @('Live', 'Unknown')
            $orphaned = $hasStaleReference -and -not $hasBlockingReference
            $hasLiveUninstaller = $uninstallState -eq 'Live' -or $quietUninstallState -eq 'Live'
            $reason = if ($orphaned) {
                '360-family uninstall record has stale file references and no live install location or vendor uninstaller.'
            }
            elseif ($hasLiveUninstaller) {
                '360-family product record has a live vendor uninstaller; run it before registry cleanup.'
            }
            elseif ($locationState -eq 'Live') {
                '360-family product record has a live install location; inspect it and prefer its vendor uninstaller first.'
            }
            else {
                'There is not enough evidence to prove this uninstall record is orphaned; inspect its file references before registry cleanup.'
            }
            $productFinding = New-Finding -Kind 'InstalledProduct' -Name $displayName -Target $key.PSPath `
                -Confidence $(if ($orphaned) { 'Confirmed' } else { 'ReviewOnly' }) `
                -Reason $reason -RemovalType $(if ($orphaned) { 'RegistryKey' } else { 'None' })
            if ($orphaned) {
                $productIdentity = Get-360CleanupNonPathIdentityState -Finding $productFinding `
                    -ObservedIdentity $properties
                $productFinding = Set-360CleanupFindingIdentityFingerprint -Finding $productFinding `
                    -IdentityState $productIdentity
            }
            if ($isExactDuohuiRecord -and $productFinding.Confidence -eq 'Confirmed') {
                $duohuiOrphanedRecord = $true
            }
            Add-Finding $findings $productFinding
        }
    }

    $duohuiRegistryResidues = New-Object System.Collections.ArrayList
    $currentUserSoftwareRoot = $currentUserRegistryRoot + '\Software'
    $directDuohuiResidue = $currentUserSoftwareRoot + '\duohuipingbao'
    if (Test-360CleanupRegistryPath $directDuohuiResidue) {
        [void]$duohuiRegistryResidues.Add($directDuohuiResidue)
    }
    if (Test-360CleanupRegistryPath $currentUserSoftwareRoot) {
        foreach ($parentKey in @(Get-360CleanupRegistrySubKeys $currentUserSoftwareRoot)) {
            $parentName = Get-RegistryKeyLeafName $parentKey
            if ($parentName -notmatch '^\{[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\}$') { continue }
            $parentPropertyNames = @($parentKey.PSObject.Properties.Name)
            if ($parentPropertyNames -notcontains 'PSPath' -or
                [string]::IsNullOrWhiteSpace([string]$parentKey.PSPath)) { continue }
            $guidDuohuiResidue = ([string]$parentKey.PSPath).TrimEnd('\') + '\duohuipingbao'
            if (Test-360CleanupRegistryPath $guidDuohuiResidue) {
                [void]$duohuiRegistryResidues.Add($guidDuohuiResidue)
            }
        }
    }
    foreach ($residue in @($duohuiRegistryResidues | Sort-Object -Unique)) {
        $residueFinding = New-Finding -Kind 'RegistryResidue' -Name 'Duohui registry residue' `
            -Target ([string]$residue) -Confidence $(if ($duohuiOrphanedRecord) { 'Confirmed' } else { 'ReviewOnly' }) `
            -Reason $(if ($duohuiOrphanedRecord) {
                'Exact Duohui residue paired with the proven orphan HKCU duohuipingbao uninstall record.'
            } else {
                'Exact Duohui residue found without a proven orphan HKCU duohuipingbao uninstall record; review only.'
            }) -RemovalType $(if ($duohuiOrphanedRecord) { 'RegistryKey' } else { 'None' })
        if ($duohuiOrphanedRecord) {
            try { $residueRootProperties = Get-360CleanupRegistryValuesStrict ([string]$residue) }
            catch { $residueRootProperties = $null }
            $residueIdentity = Get-360CleanupNonPathIdentityState -Finding $residueFinding `
                -ObservedIdentity $residueRootProperties
            $residueFinding = Set-360CleanupFindingIdentityFingerprint -Finding $residueFinding `
                -IdentityState $residueIdentity
        }
        Add-Finding $findings $residueFinding
    }

    $confirmedRoots = Get-ConfirmedPathRoots @($findings)

    $runRoots = @(
        ($currentUserRegistryRoot + '\Software\Microsoft\Windows\CurrentVersion\Run'),
        ($currentUserRegistryRoot + '\Software\Microsoft\Windows\CurrentVersion\RunOnce'),
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($runRoot in $runRoots) {
        if (-not (Test-360CleanupRegistryPath $runRoot)) { continue }
        $properties = Get-360CleanupRegistryValues $runRoot
        foreach ($property in $properties.PSObject.Properties) {
            if ($property.Name -match '^PS') { continue }
            $executable = Get-CommandExecutable ([string]$property.Value)
            $matchedRoot = $null
            foreach ($confirmedRoot in $confirmedRoots) {
                if ($executable -and (Test-IsUnderPath $executable $confirmedRoot)) { $matchedRoot = $confirmedRoot; break }
            }
            if ($matchedRoot) {
                $startupFinding = New-Finding -Kind 'Startup' -Name $property.Name -Target $runRoot `
                    -Confidence 'Confirmed' -Reason ('Startup executable is under confirmed target: ' + $matchedRoot) `
                    -RemovalType 'RegistryValue' -ValueName $property.Name
                $startupIdentity = Get-360CleanupNonPathIdentityState -Finding $startupFinding `
                    -ObservedIdentity $property
                Add-Finding $findings (Set-360CleanupFindingIdentityFingerprint -Finding $startupFinding `
                    -IdentityState $startupIdentity)
            }
            elseif ($property.Name -match '(?i)360|SoftMgr|huabao|duohuipingbao|sesvc' -or
                ($executable -and $executable -match '(?i)360|SoftMgr|huabao|duohuipingbao|sesvc')) {
                Add-Finding $findings (New-Finding -Kind 'Startup' -Name $property.Name -Target $runRoot `
                    -Confidence 'ReviewOnly' -Reason 'Startup name/path matched a 360-family marker, but its executable was not under a confirmed target.' `
                    -RemovalType 'None' -ValueName $property.Name)
            }
        }
    }

    $desktopKey = $currentUserRegistryRoot + '\Control Panel\Desktop'
    if (Test-360CleanupRegistryPath $desktopKey) {
        $desktop = Get-360CleanupRegistryValues $desktopKey
        $screenSaverProperty = $desktop.PSObject.Properties['SCRNSAVE.EXE']
        $screenSaver = Get-NormalPath ([string](Get-PropertyValue $desktop 'SCRNSAVE.EXE'))
        foreach ($confirmedRoot in $confirmedRoots) {
            if ($screenSaver -and (Test-IsUnderPath $screenSaver $confirmedRoot)) {
                $screenSaverFinding = New-Finding -Kind 'ScreenSaver' -Name 'SCRNSAVE.EXE' -Target $desktopKey `
                    -Confidence 'Confirmed' -Reason 'Screen saver setting points under a confirmed target.' `
                    -RemovalType 'RegistryValue' -ValueName 'SCRNSAVE.EXE'
                $screenSaverIdentity = Get-360CleanupNonPathIdentityState -Finding $screenSaverFinding `
                    -ObservedIdentity $screenSaverProperty
                Add-Finding $findings (Set-360CleanupFindingIdentityFingerprint -Finding $screenSaverFinding `
                    -IdentityState $screenSaverIdentity)
                break
            }
        }
    }

    try {
        foreach ($task in @(Get-360CleanupScheduledTasks)) {
            $actionExecutables = @($task.Actions | ForEach-Object { Get-NormalPath ([string]$_.Execute) } | Where-Object { $_ })
            $matchedRoot = $null
            foreach ($action in $actionExecutables) {
                foreach ($confirmedRoot in $confirmedRoots) {
                    if (Test-IsUnderPath $action $confirmedRoot) { $matchedRoot = $confirmedRoot; break }
                }
                if ($matchedRoot) { break }
            }
            if ($matchedRoot) {
                $taskFinding = New-Finding -Kind 'ScheduledTask' -Name $task.TaskName -Target $task.TaskName `
                    -Confidence 'Confirmed' -Reason 'Task action points under an exact confirmed target.' `
                    -RemovalType 'Task' -ValueName $task.TaskPath
                $taskIdentity = Get-360CleanupNonPathIdentityState -Finding $taskFinding `
                    -ObservedIdentity $task
                Add-Finding $findings (Set-360CleanupFindingIdentityFingerprint -Finding $taskFinding `
                    -IdentityState $taskIdentity)
            }
            elseif ($task.TaskName -match '(?i)360|SoftMgr|huabao|duohuipingbao') {
                Add-Finding $findings (New-Finding -Kind 'ScheduledTask' -Name $task.TaskName -Target $task.TaskName `
                    -Confidence 'ReviewOnly' -Reason 'Task name matched, but its action was not under a confirmed target.')
            }
        }
    }
    catch {}

    foreach ($service in @(Get-360CleanupServices)) {
        $executable = Get-CommandExecutable ([string]$service.PathName)
        $matchedRoot = $null
        foreach ($confirmedRoot in $confirmedRoots) {
            if ($executable -and (Test-IsUnderPath $executable $confirmedRoot)) { $matchedRoot = $confirmedRoot; break }
        }
        $confirmedToolboxService = $softMgrConfirmed -and $service.Name -eq 'WinToolBoxUpdateSrv' -and
            $toolboxRoot -and $executable -and $executable.Equals((Get-NormalPath (Join-Path $toolboxRoot 'winToolBoxSrv.exe')), [StringComparison]::OrdinalIgnoreCase)
        if ($matchedRoot -or $confirmedToolboxService) {
            $serviceFinding = New-Finding -Kind 'Service' -Name $service.Name -Target $service.Name `
                -Confidence 'Confirmed' -Reason 'Service executable is a confirmed target or confirmed mixed-bundle updater.' `
                -RemovalType 'Service'
            $serviceIdentity = Get-360CleanupNonPathIdentityState -Finding $serviceFinding `
                -ObservedIdentity $service
            Add-Finding $findings (Set-360CleanupFindingIdentityFingerprint -Finding $serviceFinding `
                -IdentityState $serviceIdentity)
        }
        elseif ($toolboxConfirmed -and $toolboxRoot -and $executable -and
            (Test-IsUnderPath $executable $toolboxRoot)) {
            Add-Finding $findings (New-Finding -Kind 'Service' -Name $service.Name -Target $service.Name `
                -Confidence 'ReviewOnly' `
                -Reason 'Service executable is under a confirmed mixed winToolBox bundle, but this sibling toolbox service is not approved for removal.' `
                -RemovalType 'None')
        }
        elseif ($service.Name -match '(?i)360|SoftMgr|huabao|duohuipingbao' -or
            ($executable -and $executable -match '(?i)(?:^|[\\/])360[^\\/]*(?:[\\/]|$)|SoftMgr|huabao|duohuipingbao')) {
            Add-Finding $findings (New-Finding -Kind 'Service' -Name $service.Name -Target $service.Name `
                -Confidence 'ReviewOnly' -Reason 'Service name/path matched, but its executable was not under a confirmed target.')
        }
    }

    $driverRoot = Join-Path $script:KnownFolders.Windows 'System32\drivers'
    foreach ($driver in @(Get-ChildItem -LiteralPath $driverRoot -File -Filter '360*.sys' -ErrorAction SilentlyContinue)) {
        Add-Finding $findings (New-Finding -Kind 'Driver' -Name $driver.Name -Target $driver.FullName `
            -Confidence 'ReviewOnly' -Reason 'System driver requires vendor-uninstaller and driver-package review; never auto-delete.')
    }

    $confirmedRoots = Get-ConfirmedPathRoots @($findings)
    foreach ($process in @(Get-360CleanupProcesses)) {
        $path = Get-NormalPath ([string]$process.ExecutablePath)
        if (-not $path) { continue }
        foreach ($confirmedRoot in $confirmedRoots) {
            if (Test-IsUnderPath $path $confirmedRoot) {
                Add-Finding $findings (New-Finding -Kind 'Process' -Name $process.Name -Target ([string]$process.ProcessId) `
                    -Confidence 'Confirmed' -Reason ('Executable path under confirmed target: ' + $path) -RemovalType 'Process' `
                    -ValueName $path)
                break
            }
        }
    }

    if ($OfflineRoot) {
        $offline = Get-NormalPath $OfflineRoot
        if (-not $offline -or -not (Test-Path -LiteralPath (Join-Path $offline 'Windows'))) {
            throw "OfflineWindowsRoot does not contain a Windows directory: $OfflineRoot"
        }

        foreach ($relative in @('Program Files\360', 'Program Files (x86)\360', 'ProgramData\360', 'ProgramData\360safe')) {
            $path = Join-Path $offline $relative
            if (Test-Path -LiteralPath $path) {
                Add-Finding $findings (New-Finding -Kind 'OfflinePath' -Name 'Offline Windows 360 path' -Target $path `
                    -Confidence 'ReviewOnly' -Reason 'Found in another Windows installation; the bundled script is permanently scan-only for offline roots.' -Offline $true)
            }
        }

        $offlineUsers = Join-Path $offline 'Users'
        if (Test-Path -LiteralPath $offlineUsers) {
            foreach ($profile in @(Get-ChildItem -LiteralPath $offlineUsers -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($relative in @(
                    'AppData\Local\dhpingbao', 'AppData\Local\360Chrome\Chrome\Application',
                    'AppData\Local\360Chrome\Chrome\User Data', 'AppData\Local\360ChromeX\Chrome\Application',
                    'AppData\Local\360ChromeX\Chrome\User Data', 'AppData\Local\Temp\duohuipingbao',
                    'AppData\Roaming\360se6\Application', 'AppData\Roaming\360se6\User Data',
                    'AppData\Roaming\secoresdk\360se6', 'AppData\Roaming\360browser', 'AppData\Roaming\360Safe',
                    'AppData\Roaming\greencore'
                )) {
                    $path = Join-Path $profile.FullName $relative
                    if (Test-Path -LiteralPath $path) {
                        Add-Finding $findings (New-Finding -Kind 'OfflinePath' -Name 'Offline user 360 path' -Target $path `
                            -Confidence 'ReviewOnly' -Reason 'Found under another Windows user profile; scan-only.' -Offline $true)
                    }
                }
            }
        }
    }

    return @($findings)
}

function Test-IsAdministrator {
    return [bool](Invoke-360CleanupRuntimeProvider -Name 'IsAdministrator' -Default {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    })
}

function Test-IsExpectedRemovalPath {
    param([string]$Path)

    $target = Get-NormalPath $Path
    if (-not $target) { return $false }

    $exact = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    if ($script:KnownFolders.ProgramFiles) {
        [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.ProgramFiles '360')))
        [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.ProgramFiles 'softmgr')))
    }
    if ($script:KnownFolders.ProgramFilesX86) { [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.ProgramFilesX86 '360'))) }
    if ($script:KnownFolders.ProgramData) {
        [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.ProgramData '360')))
        [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.ProgramData '360safe')))
    }
    if ($script:KnownFolders.LocalAppData) {
        foreach ($relative in @(
            '360Chrome\Chrome\Application', '360Chrome\Chrome\User Data',
            '360ChromeX\Chrome\Application', '360ChromeX\Chrome\User Data'
        )) {
            [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.LocalAppData $relative)))
        }
        [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.LocalAppData 'dhpingbao')))
    }
    if ($script:KnownFolders.RoamingAppData) {
        foreach ($relative in @(
            '360se6\Application', '360se6\User Data', 'secoresdk\360se6', '360browser',
            '360Safe', '360GameAssistant', '360huabao', '360DrvMgrScrSaver', 'greencore', 'GreenCore7z'
        )) {
            [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.RoamingAppData $relative)))
        }
    }
    if ($script:KnownFolders.Temp) {
        foreach ($name in @('duohuipingbao', 'huabao_tmp', '360gameassistantYyb', '360UnPackTmp64')) {
            [void]$exact.Add((Get-NormalPath (Join-Path $script:KnownFolders.Temp $name)))
        }
    }
    if ($exact.Contains($target)) { return $true }

    if ($script:KnownFolders.Temp) {
        $tempParent = Get-NormalPath (Split-Path -Parent $target)
        $tempRoot = Get-NormalPath $script:KnownFolders.Temp
        $leaf = Split-Path -Leaf $target
        if ($tempParent -and $tempParent.Equals($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            ($leaf -eq '360greencore.cab' -or $leaf -match '(?i)^360se[^\\]*\.cab$')) { return $true }
    }

    if ($script:KnownFolders.RoamingAppData) {
        $parent = Get-NormalPath (Split-Path -Parent $target)
        if ($parent -and $parent.Equals((Get-NormalPath $script:KnownFolders.RoamingAppData), [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $target) -like 'SoftMgr*') { return $true }
    }

    if ($script:KnownFolders.LocalAppData) {
        $toolboxRoot = Get-NormalPath (Join-Path $script:KnownFolders.LocalAppData 'winToolBox')
        $toolboxServer = Get-NormalPath (Join-Path $toolboxRoot 'winToolBoxSrv.exe')
        if ($target.Equals($toolboxServer, [StringComparison]::OrdinalIgnoreCase)) { return $true }

        $toolboxTools = Get-NormalPath (Join-Path $toolboxRoot 'Tools')
        $parent = Get-NormalPath (Split-Path -Parent $target)
        if ($parent -and $parent.Equals($toolboxTools, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $target) -like 'SoftMgr*') { return $true }
        if ($parent -and $parent.Equals($toolboxRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Is360File $target)) { return $true }
    }

    return $false
}

function New-RemovalPathSafetyState {
    param(
        [ValidateSet('Safe', 'AccessDenied', 'ReparsePoint', 'Unsafe')]
        [string]$State,
        [string]$Path,
        [bool]$Exists = $false,
        [bool]$TreeScanComplete = $false,
        [string]$BlockedPath = '',
        [bool]$BlockedPathVerifiedNonReparse = $false,
        [string]$Detail = ''
    )

    return [pscustomobject]@{
        State                         = $State
        Path                          = $Path
        Exists                        = $Exists
        TreeScanComplete              = $TreeScanComplete
        BlockedPath                   = $BlockedPath
        BlockedPathVerifiedNonReparse = $BlockedPathVerifiedNonReparse
        Detail                        = $Detail
    }
}

function Test-IsPathAccessDeniedError {
    param([object]$ErrorObject)

    if ($null -eq $ErrorObject) { return $false }
    try {
        if ([string]$ErrorObject.CategoryInfo.Category -eq 'PermissionDenied' -or
            [string]$ErrorObject.FullyQualifiedErrorId -match '(?i)UnauthorizedAccess|AccessDenied|PermissionDenied') {
            return $true
        }
    }
    catch {}

    $exception = $ErrorObject
    try {
        if ($null -ne $ErrorObject.Exception) { $exception = $ErrorObject.Exception }
    }
    catch {}
    while ($null -ne $exception) {
        if ($exception -is [UnauthorizedAccessException] -or $exception -is [Security.SecurityException]) {
            return $true
        }
        if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -eq 5) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Test-IsPathNotFoundError {
    param([object]$ErrorObject)

    if ($null -eq $ErrorObject) { return $false }
    try {
        if ([string]$ErrorObject.CategoryInfo.Category -eq 'ObjectNotFound' -or
            [string]$ErrorObject.FullyQualifiedErrorId -match '(?i)PathNotFound|ItemNotFound') {
            return $true
        }
    }
    catch {}

    $exception = $ErrorObject
    try {
        if ($null -ne $ErrorObject.Exception) { $exception = $ErrorObject.Exception }
    }
    catch {}
    while ($null -ne $exception) {
        if ($exception -is [IO.FileNotFoundException] -or $exception -is [IO.DirectoryNotFoundException] -or
            $exception -is [System.Management.Automation.ItemNotFoundException]) {
            return $true
        }
        $exception = $exception.InnerException
    }
    return $false
}

function Get-PathTraversalSafetyState {
    param([string]$Path)

    $target = Get-NormalPath $Path
    if (-not $target) {
        return New-RemovalPathSafetyState -State 'Unsafe' -Path ([string]$Path) `
            -Detail 'The target is not a valid normalized path.'
    }

    $root = [IO.Path]::GetPathRoot($target)
    if ([string]::IsNullOrWhiteSpace($root) -or $target.Length -le $root.Length) {
        return New-RemovalPathSafetyState -State 'Unsafe' -Path $target `
            -Detail 'Drive and share roots are never valid recursive removal targets.'
    }

    $relative = $target.Substring($root.Length)
    $current = $root
    $targetItem = $null
    foreach ($segment in @($relative -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        try {
            $item = Get-360CleanupPathItem $current
        }
        catch {
            if (Test-IsPathNotFoundError $_) {
                return New-RemovalPathSafetyState -State 'Safe' -Path $target -Exists $false `
                    -TreeScanComplete $true -Detail 'The target is no longer present.'
            }
            $detail = if (Test-IsPathAccessDeniedError $_) {
                'The target parent chain could not be inspected; its reparse-point status is unknown.'
            }
            else { 'The target parent chain could not be inspected safely.' }
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $current -Detail ($detail + ' ' + $_.Exception.Message)
        }

        if ($null -eq $item) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $current -Detail 'Path inspection returned a null item.'
        }
        $propertyNames = @($item.PSObject.Properties.Name)
        if ($propertyNames -notcontains 'FullName' -or $propertyNames -notcontains 'Attributes' -or
            $propertyNames -notcontains 'PSIsContainer') {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $current -Detail 'Path inspection returned an incomplete item.'
        }
        $itemPath = Get-NormalPath ([string]$item.FullName)
        if (-not $itemPath -or -not $itemPath.Equals((Get-NormalPath $current), [StringComparison]::OrdinalIgnoreCase)) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $current -Detail 'Path inspection returned an incomplete or mismatched item.'
        }
        if ([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            return New-RemovalPathSafetyState -State 'ReparsePoint' -Path $target -Exists $true `
                -BlockedPath $itemPath -Detail 'The target path chain contains a reparse point.'
        }
        if (-not [bool]$item.PSIsContainer -and
            -not $itemPath.Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $itemPath -Detail 'A parent path component is not a directory.'
        }
        if ($itemPath.Equals($target, [StringComparison]::OrdinalIgnoreCase)) { $targetItem = $item }
    }

    if ($null -eq $targetItem) {
        return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
            -Detail 'The target item could not be matched to its normalized path.'
    }
    if (-not [bool]$targetItem.PSIsContainer) {
        return New-RemovalPathSafetyState -State 'Safe' -Path $target -Exists $true `
            -TreeScanComplete $true -Detail 'The exact target is a non-reparse-point file.'
    }

    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($target)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        try {
            $directoryItem = Get-360CleanupPathItem $directory
        }
        catch {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $directory `
                -Detail ('A queued directory could not be re-inspected before enumeration. ' + $_.Exception.Message)
        }
        if ($null -eq $directoryItem) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $directory -Detail 'A queued directory re-inspection returned null.'
        }
        $directoryPropertyNames = @($directoryItem.PSObject.Properties.Name)
        if ($directoryPropertyNames -notcontains 'FullName' -or $directoryPropertyNames -notcontains 'Attributes' -or
            $directoryPropertyNames -notcontains 'PSIsContainer') {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $directory -Detail 'A queued directory re-inspection returned an incomplete item.'
        }
        $observedDirectory = Get-NormalPath ([string]$directoryItem.FullName)
        if (-not $observedDirectory -or
            -not $observedDirectory.Equals($directory, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-IsUnderPath $observedDirectory $target) -or
            -not [bool]$directoryItem.PSIsContainer) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $directory -Detail 'A queued directory changed identity before enumeration.'
        }
        if ([IO.FileAttributes]$directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            return New-RemovalPathSafetyState -State 'ReparsePoint' -Path $target -Exists $true `
                -BlockedPath $observedDirectory -Detail 'A queued directory became a reparse point before enumeration.'
        }
        try {
            $children = @(Get-360CleanupPathChildren $directory)
        }
        catch {
            if (Test-IsPathAccessDeniedError $_) {
                return New-RemovalPathSafetyState -State 'AccessDenied' -Path $target -Exists $true `
                    -BlockedPath $directory -BlockedPathVerifiedNonReparse $true `
                    -Detail ('Access was denied while enumerating a directory already observed as non-reparse. ' + $_.Exception.Message)
            }
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                -BlockedPath $directory -Detail ('The target tree changed or could not be enumerated safely. ' + $_.Exception.Message)
        }

        foreach ($item in $children) {
            if ($null -eq $item) {
                return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                    -BlockedPath $directory -Detail 'Path enumeration returned a null child item.'
            }
            $propertyNames = @($item.PSObject.Properties.Name)
            if ($propertyNames -notcontains 'FullName' -or $propertyNames -notcontains 'Attributes' -or
                $propertyNames -notcontains 'PSIsContainer') {
                return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                    -BlockedPath $directory -Detail 'Path enumeration returned an incomplete child item.'
            }
            $itemPath = Get-NormalPath ([string]$item.FullName)
            $itemParent = if ($itemPath) { Get-NormalPath (Split-Path -Parent $itemPath) } else { $null }
            if (-not $itemPath -or -not $itemParent -or
                -not $itemParent.Equals($directory, [StringComparison]::OrdinalIgnoreCase)) {
                return New-RemovalPathSafetyState -State 'Unsafe' -Path $target -Exists $true `
                    -BlockedPath $directory -Detail 'Path enumeration returned an incomplete or out-of-tree child item.'
            }
            if ([IO.FileAttributes]$item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                return New-RemovalPathSafetyState -State 'ReparsePoint' -Path $target -Exists $true `
                    -BlockedPath $itemPath -Detail 'The target tree contains a reparse point.'
            }
            if ([bool]$item.PSIsContainer) { $pending.Push($itemPath) }
        }
    }

    return New-RemovalPathSafetyState -State 'Safe' -Path $target -Exists $true `
        -TreeScanComplete $true -Detail 'The complete target tree was enumerated without reparse points.'
}

function Get-RemovalPathSafetyState {
    param([string]$Path)

    $target = Get-NormalPath $Path
    if (-not $target) {
        return New-RemovalPathSafetyState -State 'Unsafe' -Path ([string]$Path) `
            -Detail 'The removal target is not a valid normalized path.'
    }
    try {
        if ($script:KnownFolders.Windows -and (Test-IsUnderPath $target $script:KnownFolders.Windows)) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target `
                -Detail 'Targets under the Windows directory are never recursively removed.'
        }
        $blocked = @(
            [IO.Path]::GetPathRoot($target),
            $script:KnownFolders.Windows,
            $script:KnownFolders.UserProfile,
            $script:KnownFolders.LocalAppData,
            $script:KnownFolders.RoamingAppData,
            $script:KnownFolders.ProgramFiles,
            $script:KnownFolders.ProgramFilesX86,
            $script:KnownFolders.ProgramData,
            $script:KnownFolders.Temp
        ) | Where-Object { $_ }
        foreach ($blockedRoot in $blocked) {
            $normalRoot = Get-NormalPath $blockedRoot
            if ($normalRoot -and $target.Equals($normalRoot, [StringComparison]::OrdinalIgnoreCase)) {
                return New-RemovalPathSafetyState -State 'Unsafe' -Path $target `
                    -Detail 'A broad known-folder or filesystem root cannot be a removal target.'
            }
        }

        $traversalState = Get-PathTraversalSafetyState $target
        if ($traversalState.State -eq 'Safe' -and -not $traversalState.Exists) {
            # A confirmed-absent target cannot be mutated. Return before dynamic metadata
            # allowlist checks, which necessarily fail after a metadata-gated file is deleted.
            return $traversalState
        }
        if ($traversalState.State -ne 'Safe') { return $traversalState }
        if (-not (Test-IsExpectedRemovalPath $target)) {
            return New-RemovalPathSafetyState -State 'Unsafe' -Path $target `
                -Exists $traversalState.Exists -BlockedPath $traversalState.BlockedPath `
                -Detail 'The target is outside the exact removal allowlist.'
        }
        return $traversalState
    }
    catch {
        return New-RemovalPathSafetyState -State 'Unsafe' -Path $target `
            -Detail ('Removal-path validation failed unexpectedly. ' + $_.Exception.Message)
    }
}

function Test-PathChainHasReparsePoint {
    param([string]$Path)

    $state = Get-PathTraversalSafetyState $Path
    return $state.State -ne 'Safe' -or -not $state.Exists
}

function Test-PathTreeHasReparsePoint {
    param([string]$Path)

    $state = Get-PathTraversalSafetyState $Path
    return $state.State -ne 'Safe' -or -not $state.Exists
}

function Test-SafeRemovalTarget {
    param([string]$Path)

    $state = Get-RemovalPathSafetyState $Path
    return $state.State -eq 'Safe' -and $state.Exists -and $state.TreeScanComplete
}

function Assert-SafeReportPath {
    param([string]$Path)

    $target = Get-NormalPath $Path
    if (-not $target) { throw 'ReportPath is not a valid file path.' }
    if ([IO.Path]::GetExtension($target) -ne '.json') { throw 'ReportPath must end with .json.' }
    if (Test-Path -LiteralPath $target) { throw "Refusing to overwrite an existing report or user file: $target" }
    return $target
}

function Get-RemovalTargetStats {
    param([string]$Path)

    $target = Get-NormalPath $Path
    if (-not $target) { throw 'The accounting target is not a valid normalized path.' }

    try { $rootItem = Get-360CleanupPathItem $target }
    catch {
        if (Test-IsPathNotFoundError $_) {
            return [pscustomobject]@{ Files = [int64]0; Directories = [int64]0; Bytes = [int64]0 }
        }
        throw
    }
    if ($null -eq $rootItem) { throw 'Accounting path inspection returned a null root item.' }
    $rootPropertyNames = @($rootItem.PSObject.Properties.Name)
    if ($rootPropertyNames -notcontains 'FullName' -or $rootPropertyNames -notcontains 'Attributes' -or
        $rootPropertyNames -notcontains 'PSIsContainer') {
        throw 'Accounting path inspection returned an incomplete root item.'
    }
    $observedRoot = Get-NormalPath ([string]$rootItem.FullName)
    if (-not $observedRoot -or -not $observedRoot.Equals($target, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Accounting path inspection returned a mismatched root item.'
    }

    $files = [int64]0
    $directories = [int64]0
    $bytes = [int64]0
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to measure a reparse-point target: $target"
    }
    if (-not $rootItem.PSIsContainer) {
        if ($rootPropertyNames -notcontains 'Length') { throw 'Accounting file inspection did not return Length.' }
        return [pscustomobject]@{ Files = [int64]1; Directories = [int64]0; Bytes = [int64]$rootItem.Length }
    }

    $directories = [int64]1
    $pending = New-Object System.Collections.Generic.Stack[string]
    $pending.Push($target)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $directoryItem = Get-360CleanupPathItem $directory
        if ($null -eq $directoryItem) { throw "Accounting directory re-inspection returned null: $directory" }
        $directoryPropertyNames = @($directoryItem.PSObject.Properties.Name)
        if ($directoryPropertyNames -notcontains 'FullName' -or
            $directoryPropertyNames -notcontains 'Attributes' -or
            $directoryPropertyNames -notcontains 'PSIsContainer') {
            throw "Accounting directory re-inspection returned an incomplete item: $directory"
        }
        $observedDirectory = Get-NormalPath ([string]$directoryItem.FullName)
        if (-not $observedDirectory -or
            -not $observedDirectory.Equals($directory, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-IsUnderPath $observedDirectory $target) -or
            -not [bool]$directoryItem.PSIsContainer) {
            throw "Accounting directory changed identity before enumeration: $directory"
        }
        if ($directoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to measure a directory that became a reparse point: $observedDirectory"
        }
        foreach ($item in @(Get-360CleanupPathChildren $directory)) {
            if ($null -eq $item) { throw "Accounting enumeration returned a null child item: $directory" }
            $propertyNames = @($item.PSObject.Properties.Name)
            if ($propertyNames -notcontains 'FullName' -or $propertyNames -notcontains 'Attributes' -or
                $propertyNames -notcontains 'PSIsContainer') {
                throw "Accounting enumeration returned an incomplete child item: $directory"
            }
            $itemPath = Get-NormalPath ([string]$item.FullName)
            $itemParent = if ($itemPath) { Get-NormalPath (Split-Path -Parent $itemPath) } else { $null }
            if (-not $itemPath -or -not $itemParent -or
                -not $itemParent.Equals($directory, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Accounting enumeration returned an out-of-tree child item: $directory"
            }
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to measure a tree containing a reparse point: $itemPath"
            }
            if ($item.PSIsContainer) {
                $directories++
                $pending.Push($itemPath)
            }
            else {
                if ($propertyNames -notcontains 'Length') { throw "Accounting file inspection did not return Length: $itemPath" }
                $files++
                $bytes += [int64]$item.Length
            }
        }
    }
    return [pscustomobject]@{ Files = $files; Directories = $directories; Bytes = $bytes }
}

function Get-TopLevelAccountingTargets {
    param([string[]]$Targets)

    $result = New-Object System.Collections.ArrayList
    foreach ($candidate in @($Targets)) {
        $nested = $false
        foreach ($other in @($Targets)) {
            if ($candidate.Equals($other, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-IsUnderPath $candidate $other) { $nested = $true; break }
        }
        if (-not $nested) { [void]$result.Add($candidate) }
    }
    return @($result)
}

function Format-ByteSize {
    param([int64]$Bytes)

    if ($Bytes -lt 1024) { return ('{0} B' -f $Bytes) }
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $value = [double]$Bytes
    $unitIndex = 0
    while ($value -ge 1024 -and $unitIndex -lt ($units.Count - 1)) {
        $value /= 1024
        $unitIndex++
    }
    return ('{0:N2} {1}' -f $value, $units[$unitIndex])
}

function Save-CleanupReport {
    param(
        [string]$Path,
        [string]$RunMode,
        [object[]]$Findings,
        [object[]]$Actions,
        [object]$Summary = $null,
        [object]$ApprovalContext = $null,
        [string]$ApprovedReportHash = $null,
        [string]$OutcomeRunId = $null,
        [bool]$IncludeIdentity = $false
    )

    $Path = Assert-SafeReportPath $Path
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $report = [pscustomobject]@{
        SchemaVersion = 2
        Timestamp    = (Get-Date).ToString('o')
        ComputerName = $(if ($IncludeIdentity) { $env:COMPUTERNAME } else { $null })
        User          = $(if ($IncludeIdentity) { [Security.Principal.WindowsIdentity]::GetCurrent().Name } else { $null })
        Mode          = $RunMode
        ApprovalContext = $ApprovalContext
        ApprovedReportHash = $ApprovedReportHash
        OutcomeRunId  = $OutcomeRunId
        Summary       = $Summary
        Findings      = @($Findings)
        Actions       = @($Actions)
    }
    $json = $report | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $writer = New-Object IO.StreamWriter($stream, $utf8)
        try { $writer.Write($json) }
        finally { $writer.Dispose() }
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Show-Findings {
    param([object[]]$Findings)

    if (@($Findings).Count -eq 0) {
        Write-Host 'No matching 360/Qihoo findings.' -ForegroundColor Green
        return
    }
    $Findings | Sort-Object Confidence, Kind, Name | Select-Object Confidence, Kind, Name, Target, Reason | Format-Table -AutoSize -Wrap
}

function Add-Action {
    param(
        [System.Collections.IList]$Actions,
        [string]$Action,
        [string]$Target,
        [string]$Result,
        [string]$Detail = ''
    )
    [void]$Actions.Add([pscustomobject]@{
        Time   = (Get-Date).ToString('o')
        Action = $Action
        Target = $Target
        Result = $Result
        Detail = $Detail
    })
}

function Join-360CleanupStableFields {
    param([object[]]$Fields)

    $builder = New-Object Text.StringBuilder
    foreach ($field in @($Fields)) {
        $text = if ($null -eq $field) { '' } else { [string]$field }
        [void]$builder.Append($text.Length)
        [void]$builder.Append(':')
        [void]$builder.Append($text)
    }
    return $builder.ToString()
}

function ConvertTo-360CleanupStableValue {
    param([object]$Value)

    if ($null -eq $Value) { return 'NULL' }
    $typeName = $Value.GetType().FullName
    if ($Value -is [byte[]]) {
        return Join-360CleanupStableFields @($typeName, [Convert]::ToBase64String([byte[]]$Value))
    }
    if ($Value -is [Array]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) {
            [void]$items.Add((ConvertTo-360CleanupStableValue $item))
        }
        return Join-360CleanupStableFields @($typeName, (Join-360CleanupStableFields @($items)))
    }
    if ($Value -is [DateTime]) {
        return Join-360CleanupStableFields @(
            $typeName,
            ([DateTime]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        )
    }
    $text = if ($Value -is [IFormattable]) {
        ([IFormattable]$Value).ToString($null, [Globalization.CultureInfo]::InvariantCulture)
    }
    else { [string]$Value }
    return Join-360CleanupStableFields @($typeName, $text)
}

function Get-360CleanupTextSha256 {
    param([string]$Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '')
    }
    finally { $sha256.Dispose() }
}

function Get-360CleanupStablePropertyToken {
    param(
        [object]$Object,
        [string]$Name
    )

    if ($null -eq $Object) { return Join-360CleanupStableFields @($Name, 'MISSING') }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return Join-360CleanupStableFields @($Name, 'MISSING') }
    return Join-360CleanupStableFields @(
        $Name,
        [string]$property.TypeNameOfValue,
        (ConvertTo-360CleanupStableValue $property.Value)
    )
}

function Get-360CleanupRegistryValuesStrict {
    param([string]$Path)

    return Invoke-360CleanupRuntimeProvider -Name 'RegistryValues' -ArgumentList @($Path) -Default {
        param($RegistryPath)
        Get-ItemProperty -LiteralPath $RegistryPath -ErrorAction Stop
    }
}

function Get-360CleanupRegistrySubKeysStrict {
    param([string]$Path)

    return @(Invoke-360CleanupRuntimeProvider -Name 'RegistrySubKeys' -ArgumentList @($Path) -Default {
        param($RegistryPath)
        Get-ChildItem -LiteralPath $RegistryPath -ErrorAction Stop
    })
}

function Get-360CleanupScheduledTasksStrict {
    return @(Invoke-360CleanupRuntimeProvider -Name 'ScheduledTasks' -Default {
        Get-ScheduledTask -ErrorAction Stop
    })
}

function Get-360CleanupServicesStrict {
    return @(Invoke-360CleanupRuntimeProvider -Name 'Services' -Default {
        Get-CimInstance Win32_Service -ErrorAction Stop
    })
}

function Get-360CleanupExactServiceController {
    param([string]$Name)

    $matches = @(Get-Service -ErrorAction Stop | Where-Object {
        $candidateName = [string]$_.Name
        $candidateName -and $candidateName.Equals($Name, [StringComparison]::OrdinalIgnoreCase)
    })
    if ($matches.Count -gt 1) {
        throw "The exact service-controller query was not unique: $Name"
    }
    if ($matches.Count -eq 0) { return $null }
    return $matches[0]
}

function Get-360CleanupProcessesStrict {
    return @(Invoke-360CleanupRuntimeProvider -Name 'Processes' -Default {
        Get-CimInstance Win32_Process -ErrorAction Stop
    })
}

function Get-360CleanupRegistryKeyStableText {
    param(
        [string]$Path,
        [object]$TraversalState,
        [object]$RootProperties = $null,
        [switch]$UseRootProperties
    )

    $TraversalState.Keys++
    if ($TraversalState.Keys -gt 256) {
        throw 'Registry-key identity exceeded the 256-key safety limit.'
    }

    $properties = if ($UseRootProperties) {
        $RootProperties
    }
    else {
        Get-360CleanupRegistryValuesStrict $Path
    }
    if ($null -eq $properties) {
        throw "Registry-key identity provider returned no value snapshot: $Path"
    }
    $providerMetadataNames = @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')
    [string[]]$valueNames = @($properties.PSObject.Properties | Where-Object {
        $providerMetadataNames -notcontains $_.Name
    } | ForEach-Object { [string]$_.Name })
    [Array]::Sort($valueNames, [StringComparer]::OrdinalIgnoreCase)
    $valueTokens = New-Object System.Collections.ArrayList
    foreach ($name in $valueNames) {
        [void]$valueTokens.Add((Get-360CleanupStablePropertyToken -Object $properties -Name $name))
    }

    $children = @(Get-360CleanupRegistrySubKeysStrict $Path)
    $childPaths = @{}
    $childNames = New-Object System.Collections.ArrayList
    foreach ($child in $children) {
        $childPath = [string](Get-PropertyValue $child 'PSPath')
        $childName = Get-RegistryKeyLeafName $child
        if ([string]::IsNullOrWhiteSpace($childPath) -or
            [string]::IsNullOrWhiteSpace($childName)) {
            throw "Registry-key identity provider returned an incomplete child key: $Path"
        }
        if ($childPaths.ContainsKey($childName)) {
            throw "Registry-key identity provider returned a duplicate child key: $Path"
        }
        $childPaths[$childName] = $childPath
        [void]$childNames.Add($childName)
    }
    [string[]]$orderedChildNames = @($childNames)
    [Array]::Sort($orderedChildNames, [StringComparer]::OrdinalIgnoreCase)
    $childTokens = New-Object System.Collections.ArrayList
    foreach ($childName in $orderedChildNames) {
        $childText = Get-360CleanupRegistryKeyStableText -Path ([string]$childPaths[$childName]) `
            -TraversalState $TraversalState
        [void]$childTokens.Add((Join-360CleanupStableFields @($childName, $childText)))
    }

    return Join-360CleanupStableFields @(
        (Join-360CleanupStableFields @($valueTokens)),
        (Join-360CleanupStableFields @($childTokens))
    )
}

function Test-TextReferencesDuohuiPath {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $Text = ([Environment]::ExpandEnvironmentVariables($Text)).Replace('/', '\')
    if ($Text -match '(?i)(?:^|\\)(?:dhpingbao|duohuipingbao|huabao_tmp)(?:\\|$)') {
        return $true
    }
    foreach ($root in @(Get-DuohuiCleanupPathRoots)) {
        $comparableRoot = ([string]$root).Replace('/', '\')
        if ($Text.IndexOf($comparableRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function Test-IsPathIndependentFromDuohui {
    param([string]$Path)

    $normal = Get-NormalPath $Path
    if (-not $normal) { return $false }
    foreach ($root in @(Get-DuohuiCleanupPathRoots)) {
        if (Test-IsUnderPath $normal $root) { return $false }
    }
    return $true
}

function Get-360CleanupServiceIdentityStateFromSnapshot {
    param(
        [object]$Finding,
        [object]$Service
    )

    if ($null -eq $Service) { throw 'The service identity query returned no snapshot.' }
    $requiredProperties = @('Name', 'PathName', 'StartName', 'ServiceType', 'StartMode')
    foreach ($propertyName in $requiredProperties) {
        if ($null -eq $Service.PSObject.Properties[$propertyName]) {
            throw "The service identity snapshot is missing $propertyName."
        }
    }
    $serviceName = [string](Get-PropertyValue $Service 'Name')
    if ([string]::IsNullOrWhiteSpace($serviceName) -or
        -not $serviceName.Equals([string]$Finding.Target, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The service identity snapshot does not match the finding target.'
    }

    $tokens = foreach ($propertyName in $requiredProperties) {
        Get-360CleanupStablePropertyToken -Object $Service -Name $propertyName
    }
    $pathName = [string](Get-PropertyValue $Service 'PathName')
    $executable = Get-CommandExecutable $pathName
    return [pscustomobject]@{
        State = 'Present'
        Fingerprint = Get-360CleanupTextSha256 (Join-360CleanupStableFields @($tokens))
        Independent = [bool]((Test-IsPathIndependentFromDuohui $executable) -and
            -not (Test-TextReferencesDuohuiPath $pathName))
        Detail = ''
    }
}

function Get-360CleanupTaskIdentityStateFromSnapshot {
    param(
        [object]$Finding,
        [object]$Task
    )

    if ($null -eq $Task) { throw 'The scheduled-task identity query returned no snapshot.' }
    foreach ($propertyName in @('TaskName', 'TaskPath', 'Actions')) {
        if ($null -eq $Task.PSObject.Properties[$propertyName]) {
            throw "The scheduled-task identity snapshot is missing $propertyName."
        }
    }
    $taskName = [string](Get-PropertyValue $Task 'TaskName')
    $taskPath = [string](Get-PropertyValue $Task 'TaskPath')
    if ([string]::IsNullOrWhiteSpace($taskName) -or [string]::IsNullOrWhiteSpace($taskPath) -or
        -not $taskName.Equals([string]$Finding.Target, [StringComparison]::OrdinalIgnoreCase) -or
        -not $taskPath.Equals([string]$Finding.ValueName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The scheduled-task identity snapshot does not match the finding target.'
    }

    $actionsProperty = $Task.PSObject.Properties['Actions']
    if ($null -eq $actionsProperty.Value) {
        throw 'The scheduled-task identity snapshot did not return actions.'
    }
    $actionTokens = New-Object System.Collections.ArrayList
    $independent = $true
    $actionIndex = 0
    foreach ($action in @($actionsProperty.Value)) {
        if ($null -eq $action) { throw 'The scheduled-task identity snapshot contains a null action.' }
        foreach ($propertyName in @('Execute', 'Arguments', 'WorkingDirectory')) {
            if ($null -eq $action.PSObject.Properties[$propertyName]) {
                throw "The scheduled-task action identity snapshot is missing $propertyName."
            }
        }
        $execute = [string](Get-PropertyValue $action 'Execute')
        $arguments = [string](Get-PropertyValue $action 'Arguments')
        $workingDirectory = [string](Get-PropertyValue $action 'WorkingDirectory')
        [void]$actionTokens.Add((Join-360CleanupStableFields @(
            $actionIndex,
            (Get-360CleanupStablePropertyToken -Object $action -Name 'Execute'),
            (Get-360CleanupStablePropertyToken -Object $action -Name 'Arguments'),
            (Get-360CleanupStablePropertyToken -Object $action -Name 'WorkingDirectory')
        )))
        if (-not (Test-IsPathIndependentFromDuohui $execute) -or
            (Test-TextReferencesDuohuiPath $arguments) -or
            (Test-TextReferencesDuohuiPath $workingDirectory)) {
            $independent = $false
        }
        $actionIndex++
    }
    $taskText = Join-360CleanupStableFields @(
        (Get-360CleanupStablePropertyToken -Object $Task -Name 'TaskName'),
        (Get-360CleanupStablePropertyToken -Object $Task -Name 'TaskPath'),
        (Join-360CleanupStableFields @($actionTokens))
    )
    return [pscustomobject]@{
        State = 'Present'; Fingerprint = Get-360CleanupTextSha256 $taskText
        Independent = [bool]$independent; Detail = ''
    }
}

function Get-360CleanupRegistryValueIdentityStateFromSnapshot {
    param(
        [object]$Finding,
        [object]$Property
    )

    if ($null -eq $Property) { throw 'The registry-value identity query returned no snapshot.' }
    foreach ($propertyName in @('Name', 'TypeNameOfValue', 'Value')) {
        if ($null -eq $Property.PSObject.Properties[$propertyName]) {
            throw "The registry-value identity snapshot is missing $propertyName."
        }
    }
    $valueName = [string](Get-PropertyValue $Property 'Name')
    if ([string]::IsNullOrWhiteSpace($valueName) -or
        -not $valueName.Equals([string]$Finding.ValueName, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The registry-value identity snapshot does not match the finding target.'
    }

    $value = Get-PropertyValue $Property 'Value'
    $token = Join-360CleanupStableFields @(
        $valueName,
        [string](Get-PropertyValue $Property 'TypeNameOfValue'),
        (ConvertTo-360CleanupStableValue $value)
    )
    $valueText = [string]$value
    $executable = Get-CommandExecutable $valueText
    return [pscustomobject]@{
        State = 'Present'; Fingerprint = Get-360CleanupTextSha256 $token
        Independent = [bool]((Test-IsPathIndependentFromDuohui $executable) -and
            -not (Test-TextReferencesDuohuiPath $valueText)); Detail = ''
    }
}

function Get-360CleanupRegistryKeyIdentityStateFromSnapshot {
    param(
        [object]$Finding,
        [object]$RootProperties
    )

    if ($null -eq $RootProperties) { throw 'The registry-key identity query returned no root snapshot.' }
    $traversalState = [pscustomobject]@{ Keys = 0 }
    $keyText = Get-360CleanupRegistryKeyStableText -Path ([string]$Finding.Target) `
        -TraversalState $traversalState -RootProperties $RootProperties -UseRootProperties
    return [pscustomobject]@{
        State = 'Present'; Fingerprint = Get-360CleanupTextSha256 $keyText
        Independent = $false; Detail = ''
    }
}

function Get-360CleanupNonPathIdentityState {
    param(
        [object]$Finding,
        [object]$ObservedIdentity = $null
    )

    $useObservedIdentity = $PSBoundParameters.ContainsKey('ObservedIdentity')
    try {
        switch ([string]$Finding.RemovalType) {
            'Service' {
                if ($useObservedIdentity) {
                    return Get-360CleanupServiceIdentityStateFromSnapshot -Finding $Finding -Service $ObservedIdentity
                }
                $matches = @(Get-360CleanupServicesStrict | Where-Object {
                    $name = [string](Get-PropertyValue $_ 'Name')
                    $name -and $name.Equals([string]$Finding.Target, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($matches.Count -eq 0) {
                    return [pscustomobject]@{ State = 'Absent'; Fingerprint = ''; Independent = $false; Detail = '' }
                }
                if ($matches.Count -ne 1) { throw 'The service identity query was not unique.' }
                return Get-360CleanupServiceIdentityStateFromSnapshot -Finding $Finding -Service $matches[0]
            }
            'Task' {
                if ($useObservedIdentity) {
                    return Get-360CleanupTaskIdentityStateFromSnapshot -Finding $Finding -Task $ObservedIdentity
                }
                $matches = @(Get-360CleanupScheduledTasksStrict | Where-Object {
                    $name = [string](Get-PropertyValue $_ 'TaskName')
                    $path = [string](Get-PropertyValue $_ 'TaskPath')
                    $name -and $path -and
                        $name.Equals([string]$Finding.Target, [StringComparison]::OrdinalIgnoreCase) -and
                        $path.Equals([string]$Finding.ValueName, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($matches.Count -eq 0) {
                    return [pscustomobject]@{ State = 'Absent'; Fingerprint = ''; Independent = $false; Detail = '' }
                }
                if ($matches.Count -ne 1) { throw 'The scheduled-task identity query was not unique.' }
                return Get-360CleanupTaskIdentityStateFromSnapshot -Finding $Finding -Task $matches[0]
            }
            'RegistryValue' {
                if ($useObservedIdentity) {
                    return Get-360CleanupRegistryValueIdentityStateFromSnapshot -Finding $Finding -Property $ObservedIdentity
                }
                if (-not (Test-360CleanupRegistryPath ([string]$Finding.Target))) {
                    return [pscustomobject]@{ State = 'Absent'; Fingerprint = ''; Independent = $false; Detail = '' }
                }
                $properties = Get-360CleanupRegistryValuesStrict ([string]$Finding.Target)
                if ($null -eq $properties) { throw 'The registry-value identity query returned no key snapshot.' }
                $matches = @($properties.PSObject.Properties | Where-Object {
                    $_.Name.Equals([string]$Finding.ValueName, [StringComparison]::OrdinalIgnoreCase)
                })
                if ($matches.Count -eq 0) {
                    return [pscustomobject]@{ State = 'Absent'; Fingerprint = ''; Independent = $false; Detail = '' }
                }
                if ($matches.Count -ne 1) { throw 'The registry-value identity query was not unique.' }
                return Get-360CleanupRegistryValueIdentityStateFromSnapshot -Finding $Finding -Property $matches[0]
            }
            'RegistryKey' {
                if ($useObservedIdentity) {
                    return Get-360CleanupRegistryKeyIdentityStateFromSnapshot -Finding $Finding `
                        -RootProperties $ObservedIdentity
                }
                if (-not (Test-360CleanupRegistryPath ([string]$Finding.Target))) {
                    return [pscustomobject]@{ State = 'Absent'; Fingerprint = ''; Independent = $false; Detail = '' }
                }
                $rootProperties = Get-360CleanupRegistryValuesStrict ([string]$Finding.Target)
                return Get-360CleanupRegistryKeyIdentityStateFromSnapshot -Finding $Finding `
                    -RootProperties $rootProperties
            }
            default { throw "Unsupported post-vendor identity type: $($Finding.RemovalType)" }
        }
    }
    catch {
        return [pscustomobject]@{
            State = 'Unreadable'; Fingerprint = ''; Independent = $false
            Detail = $_.Exception.Message
        }
    }
}

function Set-360CleanupFindingIdentityFingerprint {
    param(
        [object]$Finding,
        [object]$IdentityState = $null
    )

    $identity = if ($PSBoundParameters.ContainsKey('IdentityState')) {
        $IdentityState
    }
    else {
        Get-360CleanupNonPathIdentityState $Finding
    }
    if ($identity.State -eq 'Present' -and
        [string]$identity.Fingerprint -match '^[0-9A-F]{64}$') {
        $Finding.IdentityFingerprint = [string]$identity.Fingerprint
        return $Finding
    }

    $Finding.Confidence = 'ReviewOnly'
    $Finding.RemovalType = 'None'
    $Finding.IdentityFingerprint = ''
    $detail = if ($identity.Detail) { ' ' + [string]$identity.Detail } else { '' }
    $Finding.Reason = ([string]$Finding.Reason) +
        ' Exact identity fingerprint could not be captured; automatic removal is disabled.' + $detail
    return $Finding
}

function Get-360CleanupPostVendorDisposition {
    param(
        [object]$Finding,
        [object]$Before,
        [bool]$VendorPending
    )

    $after = Get-360CleanupNonPathIdentityState $Finding
    if ($after.State -eq 'Unreadable') {
        return [pscustomobject]@{
            State = 'Failed'
            Detail = 'ReasonCode=PostVendorIdentityUnreadable; The exact target identity could not be re-read, so mutation was skipped. ' + $after.Detail
        }
    }
    if ($after.State -eq 'Absent') {
        return [pscustomobject]@{
            State = 'AlreadyAbsent'; Detail = 'The exact target was already absent after the vendor-uninstaller phase.'
        }
    }
    if ($null -eq $Before -or $Before.State -ne 'Present' -or
        -not ([string]$after.Fingerprint).Equals([string]$Before.Fingerprint, [StringComparison]::Ordinal)) {
        return [pscustomobject]@{
            State = 'Failed'
            Detail = 'ReasonCode=PostVendorIdentityChanged; The exact target identity changed after the vendor-uninstaller phase, so mutation was skipped.'
        }
    }
    if ($VendorPending -and -not $after.Independent) {
        return [pscustomobject]@{
            State = 'Skipped'
            Detail = 'ReasonCode=VendorUninstallerPending; Independence from the still-running vendor process was not proven, so the target remains unresolved.'
        }
    }
    return [pscustomobject]@{ State = 'Ready'; Detail = '' }
}

function Get-360CleanupDuohuiProcessState {
    try {
        $roots = @(Get-DuohuiCleanupPathRoots)
        if ($roots.Count -ne 3) {
            return [pscustomobject]@{ State = 'Unknown'; Detail = 'The complete Duohui path-root set was unavailable.' }
        }
        foreach ($process in @(Get-360CleanupProcessesStrict)) {
            if ($null -eq $process) {
                return [pscustomobject]@{ State = 'Unknown'; Detail = 'The process provider returned a null entry.' }
            }
            $propertyNames = @($process.PSObject.Properties.Name)
            if ($propertyNames -notcontains 'ExecutablePath') {
                return [pscustomobject]@{ State = 'Unknown'; Detail = 'The process provider returned an entry without ExecutablePath.' }
            }
            $path = Get-NormalPath ([string]$process.ExecutablePath)
            foreach ($root in $roots) {
                if ($path -and (Test-IsUnderPath $path $root)) {
                    return [pscustomobject]@{
                        State = 'Running'; Detail = 'A process executable still resides under an exact Duohui cleanup root: ' + $path
                    }
                }
            }
        }
        return [pscustomobject]@{ State = 'Clear'; Detail = '' }
    }
    catch {
        return [pscustomobject]@{ State = 'Unknown'; Detail = $_.Exception.Message }
    }
}

function Remove-ConfirmedFindings {
    param(
        [object[]]$Findings,
        [switch]$AllowExplorerRestart,
        [switch]$ForceLockedTargets,
        [System.Collections.IDictionary]$Summary = $null
    )

    $actions = New-Object System.Collections.ArrayList
    $confirmed = @($Findings | Where-Object { $_.Confidence -eq 'Confirmed' -and -not $_.Offline })
    $pathTargets = @($confirmed | Where-Object { $_.RemovalType -eq 'Path' } | ForEach-Object { $_.Target } | Sort-Object -Unique)
    if ($confirmed.Count -gt 256 -or $pathTargets.Count -gt 64) {
        throw 'Safety limit exceeded: too many confirmed targets. Stop and review the detector output instead of broadening deletion.'
    }

    $nonPathIdentityBaseline = @{}
    foreach ($finding in @($confirmed | Where-Object {
        $_.RemovalType -in @('Service', 'Task', 'RegistryValue', 'RegistryKey')
    })) {
        $approvedFingerprint = [string](Get-PropertyValue $finding 'IdentityFingerprint')
        if ($approvedFingerprint -notmatch '^[0-9A-F]{64}$') {
            throw "Removal preflight rejected a $($finding.RemovalType) finding without an uppercase identity fingerprint. No changes were made."
        }
        $identity = Get-360CleanupNonPathIdentityState $finding
        if ($identity.State -ne 'Present' -or
            -not ([string]$identity.Fingerprint).Equals($approvedFingerprint, [StringComparison]::Ordinal)) {
            $identityDetail = if ($identity.Detail) { ' ' + [string]$identity.Detail } else { '' }
            throw "Removal preflight could not match the approved $($finding.RemovalType) identity for $($finding.Target). No changes were made.$identityDetail"
        }
        $identityKey = Get-FindingResourceKey -Finding $finding -UserSid ''
        $nonPathIdentityBaseline[$identityKey] = $identity
    }

    $safePathTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $accessDeniedPathTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $observedAccessDeniedPathTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $unmeasuredPathTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $unresolvedPathTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($target in $pathTargets) {
        $state = Get-RemovalPathSafetyState $target
        switch ($state.State) {
            'Safe' {
                if ($state.Exists) { [void]$safePathTargets.Add($state.Path) }
            }
            'AccessDenied' {
                if (-not $state.BlockedPathVerifiedNonReparse -or
                    -not (Test-IsUnderPath $state.BlockedPath $state.Path)) {
                    throw "Removal preflight returned an unrepairable access-denied state for path target: $target. No changes were made."
                }
                [void]$accessDeniedPathTargets.Add($state.Path)
                [void]$observedAccessDeniedPathTargets.Add($state.Path)
                [void]$unmeasuredPathTargets.Add($state.Path)
                [void]$unresolvedPathTargets.Add($state.Path)
            }
            'ReparsePoint' {
                throw "Removal preflight found a reparse point for path target: $target ($($state.BlockedPath)). No changes were made."
            }
            'Unsafe' {
                throw "Removal preflight rejected path target: $target. $($state.Detail) No changes were made."
            }
            default {
                throw "Removal preflight returned an unknown state for path target: $target. No changes were made."
            }
        }
    }

    # Count only top-level targets so nested allowlisted paths are never double-counted.
    $accountingTargets = @(Get-TopLevelAccountingTargets $pathTargets)
    $initialPathStats = @{}
    foreach ($target in $accountingTargets) {
        if ($accessDeniedPathTargets.Contains($target)) { continue }
        if (-not $safePathTargets.Contains($target)) { continue }
        try { $initialPathStats[$target] = Get-RemovalTargetStats $target }
        catch {
            $state = Get-RemovalPathSafetyState $target
            if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse) {
                [void]$safePathTargets.Remove($target)
                [void]$accessDeniedPathTargets.Add($target)
                [void]$observedAccessDeniedPathTargets.Add($target)
                [void]$unmeasuredPathTargets.Add($target)
                [void]$unresolvedPathTargets.Add($target)
                continue
            }
            if ($state.State -eq 'Safe' -and -not $state.Exists) {
                [void]$safePathTargets.Remove($target)
                continue
            }
            throw "Removal accounting preflight failed for path target: $target. No changes were made. $($_.Exception.Message)"
        }
    }

    # Accounting itself can race with filesystem changes. Revalidate every target
    # once more before the first service, task, registry, process, ACL, or path mutation.
    foreach ($target in @($safePathTargets)) {
        $state = Get-RemovalPathSafetyState $target
        if ($state.State -eq 'Safe' -and $state.TreeScanComplete) {
            if (-not $state.Exists) { [void]$safePathTargets.Remove($target) }
            continue
        }
        if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse -and
            (Test-IsUnderPath $state.BlockedPath $state.Path)) {
            [void]$safePathTargets.Remove($target)
            [void]$accessDeniedPathTargets.Add($state.Path)
            [void]$observedAccessDeniedPathTargets.Add($state.Path)
            [void]$unmeasuredPathTargets.Add($state.Path)
            [void]$unresolvedPathTargets.Add($state.Path)
            continue
        }
        if ($state.State -eq 'ReparsePoint') {
            throw "Final removal preflight found a reparse point for path target: $target ($($state.BlockedPath)). No changes were made."
        }
        throw "Final removal preflight could not prove path target safe: $target. $($state.Detail) No changes were made."
    }

    foreach ($target in @($accessDeniedPathTargets)) {
        $state = Get-RemovalPathSafetyState $target
        if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse -and
            (Test-IsUnderPath $state.BlockedPath $state.Path)) {
            [void]$observedAccessDeniedPathTargets.Add($state.Path)
            continue
        }
        if ($state.State -eq 'Safe' -and $state.TreeScanComplete) {
            [void]$accessDeniedPathTargets.Remove($target)
            if (-not $state.Exists) {
                [void]$unmeasuredPathTargets.Remove($target)
                [void]$unresolvedPathTargets.Remove($target)
                continue
            }

            $isAccountingTarget = @($accountingTargets | Where-Object {
                $_.Equals($target, [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if ($isAccountingTarget -and -not $initialPathStats.ContainsKey($target)) {
                try { $initialPathStats[$target] = Get-RemovalTargetStats $target }
                catch {
                    $measurementError = $_
                    $measurementState = Get-RemovalPathSafetyState $target
                    if ($measurementState.State -eq 'AccessDenied' -and
                        $measurementState.BlockedPathVerifiedNonReparse -and
                        (Test-IsUnderPath $measurementState.BlockedPath $target)) {
                        [void]$accessDeniedPathTargets.Add($target)
                        [void]$observedAccessDeniedPathTargets.Add($target)
                        continue
                    }
                    if ($measurementState.State -eq 'Safe' -and -not $measurementState.Exists) {
                        [void]$unmeasuredPathTargets.Remove($target)
                        [void]$unresolvedPathTargets.Remove($target)
                        continue
                    }
                    throw "Final removal accounting preflight failed for path target: $target. No changes were made. $($measurementError.Exception.Message)"
                }
            }
            [void]$safePathTargets.Add($target)
            [void]$unmeasuredPathTargets.Remove($target)
            continue
        }
        if ($state.State -eq 'ReparsePoint') {
            throw "Final removal preflight exposed a reparse point in an access-denied target: $target ($($state.BlockedPath)). No changes were made."
        }
        throw "Final removal preflight could not safely revalidate access-denied target: $target. $($state.Detail) No changes were made."
    }

    $vendorFindings = @($confirmed | Where-Object { $_.RemovalType -eq 'VendorUninstaller' })

    $postVendorMutationBlocked = $false
    $vendorPending = $false
    $vendorPendingPathTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $expectedDuohuiRoot = if ($script:KnownFolders.LocalAppData) {
        Get-NormalPath (Join-Path $script:KnownFolders.LocalAppData 'dhpingbao')
    }
    else { $null }
    foreach ($finding in $vendorFindings) {
        $vendorResult = $null
        $pairedRoots = @($confirmed | Where-Object {
            $_.RemovalType -eq 'Path' -and $expectedDuohuiRoot -and
            (Get-NormalPath ([string]$_.Target)) -and
            (Get-NormalPath ([string]$_.Target)).Equals($expectedDuohuiRoot, [StringComparison]::OrdinalIgnoreCase)
        })
        if ([string]$finding.Kind -ne 'VendorUninstaller' -or $pairedRoots.Count -ne 1) {
            $vendorResult = [pscustomobject]@{
                Result = 'Failed'; ExitCode = $null
                Detail = 'The vendor uninstaller requires exactly one eligible, exact dhpingbao Path finding in the same removal set.'
            }
        }
        elseif (-not $safePathTargets.Contains($expectedDuohuiRoot)) {
            $vendorResult = [pscustomobject]@{
                Result = 'Failed'; ExitCode = $null
                Detail = 'The paired dhpingbao root was not in the fully inspected Safe path set; the vendor uninstaller was not started.'
            }
        }
        else {
            $pairedRootState = Get-RemovalPathSafetyState $expectedDuohuiRoot
            if ($pairedRootState.State -ne 'Safe' -or -not $pairedRootState.Exists -or
                -not $pairedRootState.TreeScanComplete) {
                $vendorResult = [pscustomobject]@{
                    Result = 'Failed'; ExitCode = $null
                    Detail = 'The paired dhpingbao root was not proven Safe by a complete scan immediately before launch.'
                }
            }
            else {
                $vendorResult = Invoke-ApprovedDuohuiVendorUninstaller $finding
            }
        }

        if ([string]$vendorResult.Result -eq 'Success') {
            $processState = Get-360CleanupDuohuiProcessState
            if ($processState.State -ne 'Clear') {
                $vendorResult = [pscustomobject]@{
                    Result = 'Pending'; ExitCode = $vendorResult.ExitCode
                    Detail = 'The launched vendor process exited, but completion is not proven because a helper may still be running. It was not terminated. ' + $processState.Detail
                }
            }
        }

        $vendorDetail = [string]$vendorResult.Detail
        if ($null -ne $vendorResult.ExitCode) {
            $vendorDetail = ('ExitCode={0}; {1}' -f $vendorResult.ExitCode, $vendorDetail)
        }
        Add-Action $actions 'RunVendorUninstaller' ([string]$finding.Target) `
            ([string]$vendorResult.Result) $vendorDetail
        if ([string]$vendorResult.Result -eq 'Pending') {
            $vendorPending = $true
            foreach ($target in $pathTargets) {
                if (Test-IsExactDuohuiCleanupPath $target) {
                    [void]$vendorPendingPathTargets.Add((Get-NormalPath $target))
                }
            }
        }
    }

    # The vendor process can remove or replace approved leftovers. Revalidate every
    # path globally before any service, task, registry, process, or path mutation.
    if ($vendorFindings.Count -gt 0) {
        foreach ($target in $pathTargets) {
            $state = Get-RemovalPathSafetyState $target
            if ($state.State -eq 'Safe' -and $state.TreeScanComplete) {
                [void]$accessDeniedPathTargets.Remove($target)
                if (-not $state.Exists) {
                    [void]$safePathTargets.Remove($target)
                    [void]$vendorPendingPathTargets.Remove($target)
                    [void]$unmeasuredPathTargets.Remove($target)
                    [void]$unresolvedPathTargets.Remove($target)
                    continue
                }
                if ($vendorPendingPathTargets.Contains($target)) {
                    [void]$safePathTargets.Remove($target)
                    [void]$unresolvedPathTargets.Add($target)
                    continue
                }

                [void]$safePathTargets.Add($target)
                $isAccountingTarget = @($accountingTargets | Where-Object {
                    $_.Equals($target, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0
                if ($isAccountingTarget -and -not $initialPathStats.ContainsKey($target)) {
                    try {
                        $initialPathStats[$target] = Get-RemovalTargetStats $target
                        [void]$unmeasuredPathTargets.Remove($target)
                    }
                    catch {
                        $measurementError = $_
                        $measurementState = Get-RemovalPathSafetyState $target
                        if ($measurementState.State -eq 'AccessDenied' -and
                            $measurementState.BlockedPathVerifiedNonReparse -and
                            (Test-IsUnderPath $measurementState.BlockedPath $target)) {
                            [void]$safePathTargets.Remove($target)
                            [void]$accessDeniedPathTargets.Add($target)
                            [void]$observedAccessDeniedPathTargets.Add($target)
                            [void]$unmeasuredPathTargets.Add($target)
                            [void]$unresolvedPathTargets.Add($target)
                            continue
                        }
                        $measurementReasonCode = if ($measurementState.State -eq 'ReparsePoint') {
                            'ReparsePoint'
                        }
                        else { 'UnknownInspectionError' }
                        Add-Action $actions 'PostVendorPathPreflight' $target 'Failed' `
                            ("ReasonCode=$measurementReasonCode; All subsequent mutations were blocked. " +
                                $measurementError.Exception.Message + ' ' + $measurementState.Detail)
                        $postVendorMutationBlocked = $true
                        break
                    }
                }
                continue
            }
            if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse -and
                (Test-IsUnderPath $state.BlockedPath $state.Path)) {
                [void]$safePathTargets.Remove($target)
                [void]$accessDeniedPathTargets.Add($target)
                [void]$observedAccessDeniedPathTargets.Add($target)
                [void]$unmeasuredPathTargets.Add($target)
                [void]$unresolvedPathTargets.Add($target)
                continue
            }
            if ($state.State -eq 'ReparsePoint') {
                Add-Action $actions 'PostVendorPathPreflight' $target 'Failed' `
                    ("ReasonCode=ReparsePoint; All subsequent mutations were blocked. BlockedPath=$($state.BlockedPath)")
                $postVendorMutationBlocked = $true
                break
            }
            Add-Action $actions 'PostVendorPathPreflight' $target 'Failed' `
                ("ReasonCode=UnknownInspectionError; All subsequent mutations were blocked. $($state.Detail)")
            $postVendorMutationBlocked = $true
            break
        }

        if ($postVendorMutationBlocked) {
            foreach ($target in $pathTargets) {
                [void]$unresolvedPathTargets.Add($target)
            }
            $safePathTargets.Clear()
            $accessDeniedPathTargets.Clear()
            $vendorPendingPathTargets.Clear()
        }
        else {
            foreach ($target in @($vendorPendingPathTargets)) {
                [void]$safePathTargets.Remove($target)
                [void]$accessDeniedPathTargets.Remove($target)
                [void]$unresolvedPathTargets.Add($target)
                Add-Action $actions 'DeletePath' $target 'Skipped' `
                    'ReasonCode=VendorUninstallerPending; The vendor process was not terminated, so its related Duohui path sweep was blocked.'
            }
        }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'Service' })) {
        if ($postVendorMutationBlocked) { break }
        try {
            $identityKey = Get-FindingResourceKey -Finding $finding -UserSid ''
            $disposition = Get-360CleanupPostVendorDisposition -Finding $finding `
                -Before $nonPathIdentityBaseline[$identityKey] -VendorPending $vendorPending
            if ($disposition.State -ne 'Ready') {
                Add-Action $actions 'DeleteService' $finding.Target `
                    ([string]$disposition.State) ([string]$disposition.Detail)
                continue
            }
            $serviceController = Get-360CleanupExactServiceController ([string]$finding.Target)
            if ($null -eq $serviceController) {
                Add-Action $actions 'DeleteService' $finding.Target 'AlreadyAbsent' `
                    'The exact service was already absent immediately before the stop request.'
                continue
            }
            $serviceStoppedByCleaner = $false
            if ([string]$serviceController.Status -ne 'Stopped') {
                Stop-Service -InputObject $serviceController -ErrorAction Stop
                $serviceStoppedByCleaner = $true
            }
            $deleteDisposition = Get-360CleanupPostVendorDisposition -Finding $finding `
                -Before $nonPathIdentityBaseline[$identityKey] -VendorPending $vendorPending
            if ($deleteDisposition.State -ne 'Ready') {
                $stopDetail = if ($serviceStoppedByCleaner) {
                    'The approved exact service was stopped by this cleanup run, but it was not deleted. '
                }
                else { 'The exact service was already stopped and was not deleted. ' }
                Add-Action $actions 'DeleteService' $finding.Target `
                    ([string]$deleteDisposition.State) `
                    ($stopDetail + [string]$deleteDisposition.Detail)
                continue
            }
            $output = & sc.exe delete $finding.Target 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "sc.exe delete failed with exit code $LASTEXITCODE. $($output.Trim())" }
            if ($null -ne (Get-360CleanupExactServiceController ([string]$finding.Target))) {
                Add-Action $actions 'DeleteService' $finding.Target 'PendingRemoval' `
                    'Windows accepted the delete request, but the service still exists and may require a restart.'
            }
            else {
                Add-Action $actions 'DeleteService' $finding.Target 'Success' $output.Trim()
            }
        }
        catch { Add-Action $actions 'DeleteService' $finding.Target 'Failed' $_.Exception.Message }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'Task' })) {
        if ($postVendorMutationBlocked) { break }
        try {
            $identityKey = Get-FindingResourceKey -Finding $finding -UserSid ''
            $disposition = Get-360CleanupPostVendorDisposition -Finding $finding `
                -Before $nonPathIdentityBaseline[$identityKey] -VendorPending $vendorPending
            if ($disposition.State -ne 'Ready') {
                Add-Action $actions 'DeleteTask' ($finding.ValueName + $finding.Target) `
                    ([string]$disposition.State) ([string]$disposition.Detail)
                continue
            }
            Unregister-ScheduledTask -TaskName $finding.Target -TaskPath $finding.ValueName -Confirm:$false -ErrorAction Stop
            if ($null -ne (Get-ScheduledTask -TaskName $finding.Target -TaskPath $finding.ValueName -ErrorAction SilentlyContinue)) {
                throw 'The scheduled task still exists after the unregister request.'
            }
            Add-Action $actions 'DeleteTask' ($finding.ValueName + $finding.Target) 'Success'
        }
        catch { Add-Action $actions 'DeleteTask' ($finding.ValueName + $finding.Target) 'Failed' $_.Exception.Message }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'Process' })) {
        if ($postVendorMutationBlocked) { break }
        if ($vendorPending -and -not (Test-IsPathIndependentFromDuohui ([string]$finding.ValueName))) {
            Add-Action $actions 'StopProcess' ([string]$finding.Target) 'Skipped' `
                'ReasonCode=VendorUninstallerPending; Independence from the still-running vendor process was not proven, so the process remains unresolved.'
            continue
        }
        $processId = 0
        if (-not [int]::TryParse([string]$finding.Target, [ref]$processId)) {
            Add-Action $actions 'StopProcess' ([string]$finding.Target) 'Skipped' 'Approved process finding did not contain a valid PID.'
            continue
        }
        $result = Stop-360CleanupProcess -ProcessId $processId -ExpectedExecutable ([string]$finding.ValueName)
        Add-Action $actions 'StopProcess' ([string]$result.Target) ([string]$result.Result) ([string]$result.Detail)
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'RegistryValue' })) {
        if ($postVendorMutationBlocked) { break }
        try {
            $identityKey = Get-FindingResourceKey -Finding $finding -UserSid ''
            $disposition = Get-360CleanupPostVendorDisposition -Finding $finding `
                -Before $nonPathIdentityBaseline[$identityKey] -VendorPending $vendorPending
            if ($disposition.State -ne 'Ready') {
                Add-Action $actions 'DeleteRegistryValue' ($finding.Target + ' :: ' + $finding.ValueName) `
                    ([string]$disposition.State) ([string]$disposition.Detail)
                continue
            }
            Remove-ItemProperty -LiteralPath $finding.Target -Name $finding.ValueName -Force -ErrorAction Stop
            if ($null -ne (Get-ItemProperty -LiteralPath $finding.Target -Name $finding.ValueName -ErrorAction SilentlyContinue)) {
                throw 'The registry value still exists after the delete request.'
            }
            Add-Action $actions 'DeleteRegistryValue' ($finding.Target + ' :: ' + $finding.ValueName) 'Success'
        }
        catch { Add-Action $actions 'DeleteRegistryValue' ($finding.Target + ' :: ' + $finding.ValueName) 'Failed' $_.Exception.Message }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'RegistryKey' })) {
        if ($postVendorMutationBlocked) { break }
        try {
            $identityKey = Get-FindingResourceKey -Finding $finding -UserSid ''
            $disposition = Get-360CleanupPostVendorDisposition -Finding $finding `
                -Before $nonPathIdentityBaseline[$identityKey] -VendorPending $vendorPending
            if ($disposition.State -ne 'Ready') {
                Add-Action $actions 'DeleteRegistryKey' $finding.Target `
                    ([string]$disposition.State) ([string]$disposition.Detail)
                continue
            }
            Remove-Item -LiteralPath $finding.Target -Recurse -Force -ErrorAction Stop
            if (Test-Path -LiteralPath $finding.Target) { throw 'The registry key still exists after the delete request.' }
            Add-Action $actions 'DeleteRegistryKey' $finding.Target 'Success'
        }
        catch { Add-Action $actions 'DeleteRegistryKey' $finding.Target 'Failed' $_.Exception.Message }
    }

    $failedTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $forceTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    $accessDeniedDeleteTargets = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($target in @($safePathTargets)) {
        if ($postVendorMutationBlocked) { break }
        $state = Get-RemovalPathSafetyState $target
        if ($state.State -eq 'Safe') {
            if (-not $state.Exists) { continue }
            try {
                Remove-360CleanupPath $target
                [void]$unresolvedPathTargets.Remove($target)
                Add-Action $actions 'DeletePath' $target 'Success' 'Permanently removed; not sent to Recycle Bin.'
            }
            catch {
                [void]$failedTargets.Add($target)
                [void]$unresolvedPathTargets.Add($target)
                $reasonCode = 'DeleteFailed'
                if (Test-IsPathAccessDeniedError $_) {
                    [void]$accessDeniedDeleteTargets.Add($target)
                    [void]$observedAccessDeniedPathTargets.Add($target)
                    $reasonCode = 'AccessDenied'
                }
                Add-Action $actions 'DeletePath' $target 'RetryRequired' `
                    ("ReasonCode=$reasonCode; " + $_.Exception.Message)
            }
            continue
        }
        if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse) {
            [void]$accessDeniedPathTargets.Add($target)
            [void]$observedAccessDeniedPathTargets.Add($target)
            [void]$unmeasuredPathTargets.Add($target)
            [void]$unresolvedPathTargets.Add($target)
            continue
        }

        [void]$unresolvedPathTargets.Add($target)
        $reasonCode = if ($state.State -eq 'ReparsePoint') { 'ReparsePoint' } else { 'UnknownInspectionError' }
        Add-Action $actions 'DeletePath' $target 'Failed' `
            ("ReasonCode=$reasonCode; Target changed after the global preflight. $($state.Detail)")
    }

    $explorerStopped = $false
    if (-not $postVendorMutationBlocked -and $failedTargets.Count -gt 0) {
        $holders = New-Object System.Collections.ArrayList
        foreach ($candidateProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                foreach ($module in @($candidateProcess.Modules)) {
                    foreach ($target in $failedTargets) {
                        if ($module.FileName -and (Test-IsUnderPath $module.FileName $target)) {
                            if (@($holders | Where-Object { $_.Id -eq $candidateProcess.Id -and $_.Module -eq $module.FileName }).Count -eq 0) {
                                [void]$holders.Add([pscustomobject]@{
                                    Id = [int]$candidateProcess.Id
                                    Name = [string]$candidateProcess.ProcessName
                                    Module = [string]$module.FileName
                                })
                            }
                        }
                    }
                }
            }
            catch {}
        }
        $externalLocks = @{}
        foreach ($holder in $holders) {
            $lockedTarget = @($failedTargets | Where-Object { Test-IsUnderPath $holder.Module $_ } | Select-Object -First 1)
            $mayStop = $holder.Name -eq 'explorer' -and $AllowExplorerRestart
            if (-not $mayStop) {
                foreach ($target in $lockedTarget) { $externalLocks[(Get-NormalPath $target)] = $true }
                Add-Action $actions 'StopModuleHolder' ("{0} ({1})" -f $holder.Name, $holder.Id) 'Skipped' `
                    'A normal or system process loaded a target DLL. It was not force-stopped; close the app or reboot, then verify.'
                continue
            }
            try {
                Stop-Process -Id $holder.Id -Force -ErrorAction Stop
                $explorerStopped = $true
                Add-Action $actions 'StopModuleHolder' ("{0} ({1})" -f $holder.Name, $holder.Id) 'Success' $holder.Module
            }
            catch { Add-Action $actions 'StopModuleHolder' ([string]$holder.Id) 'Failed' $_.Exception.Message }
        }

        Start-Sleep -Milliseconds 700
        foreach ($target in @($failedTargets)) {
            $normalTarget = Get-NormalPath $target
            if ($externalLocks.ContainsKey($normalTarget)) {
                [void]$unresolvedPathTargets.Add($target)
                Add-Action $actions 'DeletePathRetry' $target 'Skipped' 'Target is held by a normal or system process that the cleaner will not force-stop.'
                continue
            }
            $state = Get-RemovalPathSafetyState $target
            if ($state.State -eq 'Safe') {
                if (-not $state.Exists) {
                    [void]$unresolvedPathTargets.Remove($target)
                    continue
                }
                try {
                    [void]$accessDeniedDeleteTargets.Remove($target)
                    Remove-360CleanupPath $target
                    [void]$unresolvedPathTargets.Remove($target)
                    Add-Action $actions 'DeletePathRetry' $target 'Success' 'Removed after the validated lock holder exited; ACLs were not changed.'
                }
                catch {
                    [void]$unresolvedPathTargets.Add($target)
                    $reasonCode = 'DeleteFailed'
                    if (Test-IsPathAccessDeniedError $_) {
                        [void]$accessDeniedDeleteTargets.Add($target)
                        [void]$observedAccessDeniedPathTargets.Add($target)
                        $reasonCode = 'AccessDenied'
                    }
                    if ($ForceLockedTargets) {
                        [void]$forceTargets.Add($target)
                        Add-Action $actions 'DeletePathRetry' $target 'RetryRequired' `
                            ("ReasonCode=$reasonCode; " + $_.Exception.Message)
                    }
                    else {
                        Add-Action $actions 'DeletePathRetry' $target 'Skipped' `
                            ("ReasonCode=$reasonCode; Still locked or access denied. Ownership was not changed. Reboot and verify first. " + $_.Exception.Message)
                    }
                }
                continue
            }
            if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse) {
                [void]$accessDeniedPathTargets.Add($target)
                [void]$observedAccessDeniedPathTargets.Add($target)
                [void]$unmeasuredPathTargets.Add($target)
                [void]$unresolvedPathTargets.Add($target)
                continue
            }

            [void]$unresolvedPathTargets.Add($target)
            $reasonCode = if ($state.State -eq 'ReparsePoint') { 'ReparsePoint' } else { 'UnknownInspectionError' }
            Add-Action $actions 'DeletePathRetry' $target 'Failed' `
                ("ReasonCode=$reasonCode; Target changed before retry. $($state.Detail)")
        }
    }

    foreach ($target in @($accessDeniedPathTargets)) {
        if ($postVendorMutationBlocked) { break }
        [void]$unresolvedPathTargets.Add($target)
        if ($ForceLockedTargets) {
            if ($forceTargets.Add($target)) {
                Add-Action $actions 'DeletePath' $target 'RetryRequired' `
                    'ReasonCode=AccessDenied; A verified non-reparse directory frontier will be considered for non-recursive ACL repair.'
            }
        }
        else {
            Add-Action $actions 'DeletePath' $target 'Skipped' `
                'ReasonCode=AccessDenied; The tree could not be fully inspected. Ownership and ACLs were not changed.'
        }
    }

    # Force processing is deliberately last. Each denied frontier may receive one
    # non-recursive ACL adjustment, followed by a complete scan from the approved root.
    foreach ($target in @($forceTargets)) {
        if ($postVendorMutationBlocked) { break }
        $repairedFrontiers = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
        $round = 0
        while ($true) {
            $round++
            if ($round -gt 64) {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=AclRepairFailed; Safety rescan limit exceeded.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }

            $state = Get-RemovalPathSafetyState $target
            $frontier = $null
            if ($state.State -eq 'Safe') {
                if (-not $state.TreeScanComplete) {
                    Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                        'ReasonCode=UnknownInspectionError; A Safe state did not include a complete tree scan.'
                    [void]$unresolvedPathTargets.Add($target)
                    break
                }
                if (-not $state.Exists) {
                    [void]$unresolvedPathTargets.Remove($target)
                    break
                }

                if (@($accountingTargets | Where-Object {
                    $_.Equals($target, [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0 -and -not $initialPathStats.ContainsKey($target)) {
                    try {
                        $initialPathStats[$target] = Get-RemovalTargetStats $target
                        [void]$unmeasuredPathTargets.Remove($target)
                    }
                    catch {
                        $measurementError = $_
                        $state = Get-RemovalPathSafetyState $target
                        if ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse -and
                            (Test-IsUnderPath $state.BlockedPath $target)) {
                            $frontier = Get-NormalPath $state.BlockedPath
                            [void]$accessDeniedPathTargets.Add($target)
                            [void]$observedAccessDeniedPathTargets.Add($target)
                            [void]$unmeasuredPathTargets.Add($target)
                        }
                        else {
                            $reasonCode = if ($state.State -eq 'ReparsePoint') { 'ReparsePoint' } else { 'UnknownInspectionError' }
                            Add-Action $actions 'MeasureRemoval' $target 'Failed' `
                                ("ReasonCode=$reasonCode; Baseline accounting after ACL repair failed. " + $measurementError.Exception.Message)
                            [void]$unmeasuredPathTargets.Add($target)
                            [void]$unresolvedPathTargets.Add($target)
                            break
                        }
                    }
                }

                if (-not $frontier) {
                    $finalState = Get-RemovalPathSafetyState $target
                    if ($finalState.State -eq 'AccessDenied' -and
                        $finalState.BlockedPathVerifiedNonReparse -and
                        (Test-IsUnderPath $finalState.BlockedPath $target)) {
                        $state = $finalState
                        $frontier = Get-NormalPath $finalState.BlockedPath
                        [void]$accessDeniedPathTargets.Add($target)
                        [void]$observedAccessDeniedPathTargets.Add($target)
                        [void]$unmeasuredPathTargets.Add($target)
                    }
                    elseif ($finalState.State -ne 'Safe' -or -not $finalState.TreeScanComplete) {
                        $reasonCode = if ($finalState.State -eq 'ReparsePoint') { 'ReparsePoint' } else { 'UnknownInspectionError' }
                        Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                            ("ReasonCode=$reasonCode; Final full-tree validation failed. $($finalState.Detail)")
                        [void]$unresolvedPathTargets.Add($target)
                        break
                    }
                    elseif (-not $finalState.Exists) {
                        [void]$unresolvedPathTargets.Remove($target)
                        break
                    }
                    elseif ($accessDeniedDeleteTargets.Contains($target)) {
                        # The latest deletion attempt, rather than tree enumeration, returned access denied.
                        # Repair only the exact approved target; the item is re-inspected again below.
                        $frontier = $target
                    }
                    else {
                        try {
                            Remove-360CleanupPath $target
                        }
                        catch {
                            if (Test-IsPathAccessDeniedError $_) {
                                [void]$accessDeniedDeleteTargets.Add($target)
                                [void]$observedAccessDeniedPathTargets.Add($target)
                                $frontier = $target
                            }
                            else {
                                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                                    ('ReasonCode=DeleteFailed; Final validated retry failed without an access-denied error; ACLs were not changed. ' + $_.Exception.Message)
                                [void]$unresolvedPathTargets.Add($target)
                                break
                            }
                        }

                        if (-not $frontier) {
                            $postRemovalState = Get-RemovalPathSafetyState $target
                            if ($postRemovalState.State -eq 'Safe' -and -not $postRemovalState.Exists) {
                                [void]$unresolvedPathTargets.Remove($target)
                                $detail = if ($repairedFrontiers.Count -gt 0) {
                                    'ACL repair was non-recursive; the complete approved root was revalidated before deletion.'
                                }
                                else { 'Removed on the final validated retry; ACLs were not changed.' }
                                Add-Action $actions 'DeletePathForceRetry' $target 'Success' $detail
                                break
                            }
                            if ($postRemovalState.State -eq 'AccessDenied' -and
                                $postRemovalState.BlockedPathVerifiedNonReparse -and
                                (Test-IsUnderPath $postRemovalState.BlockedPath $target)) {
                                $state = $postRemovalState
                                $frontier = Get-NormalPath $postRemovalState.BlockedPath
                                [void]$accessDeniedPathTargets.Add($target)
                                [void]$observedAccessDeniedPathTargets.Add($target)
                                [void]$unmeasuredPathTargets.Add($target)
                            }
                            else {
                                $reasonCode = if ($postRemovalState.State -eq 'ReparsePoint') { 'ReparsePoint' } else { 'DeleteFailed' }
                                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                                    ("ReasonCode=$reasonCode; The target was not safely absent after deletion. $($postRemovalState.Detail)")
                                [void]$unresolvedPathTargets.Add($target)
                                break
                            }
                        }
                    }
                }
            }
            elseif ($state.State -eq 'AccessDenied' -and $state.BlockedPathVerifiedNonReparse -and
                (Test-IsUnderPath $state.BlockedPath $target)) {
                $frontier = Get-NormalPath $state.BlockedPath
                [void]$accessDeniedPathTargets.Add($target)
                [void]$observedAccessDeniedPathTargets.Add($target)
                [void]$unmeasuredPathTargets.Add($target)
            }
            elseif ($state.State -eq 'ReparsePoint' -or $state.State -eq 'Unsafe') {
                $reasonCode = if ($state.State -eq 'ReparsePoint') { 'ReparsePoint' } else { 'UnknownInspectionError' }
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    ("ReasonCode=$reasonCode; Full-tree validation blocked force processing. $($state.Detail)")
                [void]$unresolvedPathTargets.Add($target)
                break
            }
            else {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=UnknownInspectionError; Access-denied frontier was not safely repairable.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }

            if (-not $frontier -or $repairedFrontiers.Contains($frontier)) {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=AclRepairFailed; The same denied frontier remained inaccessible after one repair.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }

            try {
                $frontierItem = Get-360CleanupPathItem $frontier
            }
            catch {
                if (Test-IsPathNotFoundError $_) { continue }
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    ('ReasonCode=UnknownInspectionError; Denied frontier could not be re-inspected before ACL repair. ' + $_.Exception.Message)
                [void]$unresolvedPathTargets.Add($target)
                break
            }
            if ($null -eq $frontierItem) {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=UnknownInspectionError; Denied frontier inspection returned null before ACL repair.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }
            $frontierPropertyNames = @($frontierItem.PSObject.Properties.Name)
            if ($frontierPropertyNames -notcontains 'FullName' -or
                $frontierPropertyNames -notcontains 'Attributes' -or
                $frontierPropertyNames -notcontains 'PSIsContainer') {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=UnknownInspectionError; Denied frontier inspection returned an incomplete item before ACL repair.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }
            $observedFrontier = Get-NormalPath ([string]$frontierItem.FullName)
            if (-not $observedFrontier -or
                -not $observedFrontier.Equals($frontier, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-IsUnderPath $observedFrontier $target)) {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=UnknownInspectionError; Denied frontier changed identity before ACL repair.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }
            if ([IO.FileAttributes]$frontierItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Add-Action $actions 'DeletePathForceRetry' $target 'Failed' `
                    'ReasonCode=ReparsePoint; Denied frontier became a reparse point before ACL repair.'
                [void]$unresolvedPathTargets.Add($target)
                break
            }

            [void]$repairedFrontiers.Add($frontier)
            try {
                Repair-360CleanupPathAcl $frontier
                [void]$accessDeniedDeleteTargets.Remove($target)
                Add-Action $actions 'RepairPathAcl' $frontier 'Success' `
                    'Non-recursive ownership and ACL repair; a full approved-root rescan is required next.'
            }
            catch {
                Add-Action $actions 'RepairPathAcl' $frontier 'Failed' `
                    ('ReasonCode=AclRepairFailed; No recursive ACL operation was attempted. ' + $_.Exception.Message)
                [void]$unresolvedPathTargets.Add($target)
                break
            }
        }
    }

    if (-not $postVendorMutationBlocked -and $explorerStopped) {
        try {
            Start-Process explorer.exe
            Add-Action $actions 'RestartExplorer' 'explorer.exe' 'Started'
        }
        catch { Add-Action $actions 'RestartExplorer' 'explorer.exe' 'Failed' $_.Exception.Message }
    }

    $filesRemoved = [int64]0
    $directoriesRemoved = [int64]0
    $bytesRemoved = [int64]0
    $pathTargetsRemoved = 0
    $partiallyCleanedPathTargets = 0
    foreach ($target in $accountingTargets) {
        if ($postVendorMutationBlocked) {
            [void]$unmeasuredPathTargets.Add($target)
            [void]$unresolvedPathTargets.Add($target)
            continue
        }
        if (-not $initialPathStats.ContainsKey($target)) { continue }
        $before = $initialPathStats[$target]

        $afterState = Get-RemovalPathSafetyState $target
        if ($afterState.State -ne 'Safe' -or -not $afterState.TreeScanComplete) {
            $reasonCode = 'UnknownInspectionError'
            if ($afterState.State -eq 'ReparsePoint') { $reasonCode = 'ReparsePoint' }
            elseif ($afterState.State -eq 'AccessDenied') { $reasonCode = 'AccessDenied' }
            if ($afterState.State -eq 'AccessDenied') {
                [void]$observedAccessDeniedPathTargets.Add($target)
            }
            [void]$unmeasuredPathTargets.Add($target)
            [void]$unresolvedPathTargets.Add($target)
            Add-Action $actions 'MeasureRemoval' $target 'Failed' `
                ("ReasonCode=$reasonCode; Final path accounting could not safely inspect the target. $($afterState.Detail)")
            continue
        }

        try {
            if ($afterState.Exists) {
                $after = Get-RemovalTargetStats $target
            }
            else {
                $after = [pscustomobject]@{ Files = [int64]0; Directories = [int64]0; Bytes = [int64]0 }
            }

            $fileDelta = [int64][Math]::Max([int64]0, ([int64]$before.Files - [int64]$after.Files))
            $directoryDelta = [int64][Math]::Max([int64]0, ([int64]$before.Directories - [int64]$after.Directories))
            $byteDelta = [int64][Math]::Max([int64]0, ([int64]$before.Bytes - [int64]$after.Bytes))
            $filesRemoved += $fileDelta
            $directoriesRemoved += $directoryDelta
            $bytesRemoved += $byteDelta

            $successfulPathAction = @($actions | Where-Object {
                $_.Action -in @('DeletePath', 'DeletePathRetry', 'DeletePathForceRetry') -and
                $_.Result -eq 'Success' -and $_.Target -eq $target
            }).Count -gt 0
            if (-not $afterState.Exists) {
                [void]$unresolvedPathTargets.Remove($target)
                $pathTargetsRemoved++
            }
            else {
                [void]$unresolvedPathTargets.Add($target)
                if (($fileDelta + $directoryDelta + $byteDelta) -gt 0) {
                    $partiallyCleanedPathTargets++
                }
                if ($successfulPathAction) {
                    Add-Action $actions 'VerifyPathRemoval' $target 'Failed' `
                        'ReasonCode=DeleteFailed; A path deletion returned success, but the approved target still exists.'
                }
            }
            [void]$unmeasuredPathTargets.Remove($target)
        }
        catch {
            $reasonCode = if (Test-IsPathAccessDeniedError $_) { 'AccessDenied' } else { 'UnknownInspectionError' }
            if ($reasonCode -eq 'AccessDenied') {
                [void]$observedAccessDeniedPathTargets.Add($target)
            }
            [void]$unmeasuredPathTargets.Add($target)
            [void]$unresolvedPathTargets.Add($target)
            Add-Action $actions 'MeasureRemoval' $target 'Failed' `
                ("ReasonCode=$reasonCode; Final path accounting failed. " + $_.Exception.Message)
        }
    }

    $serviceCount = @($actions | Where-Object { $_.Action -eq 'DeleteService' -and $_.Result -eq 'Success' }).Count
    $servicePendingCount = @($actions | Where-Object { $_.Action -eq 'DeleteService' -and $_.Result -eq 'PendingRemoval' }).Count
    $taskCount = @($actions | Where-Object { $_.Action -eq 'DeleteTask' -and $_.Result -eq 'Success' }).Count
    $registryKeyCount = @($actions | Where-Object { $_.Action -eq 'DeleteRegistryKey' -and $_.Result -eq 'Success' }).Count
    $registryValueCount = @($actions | Where-Object { $_.Action -eq 'DeleteRegistryValue' -and $_.Result -eq 'Success' }).Count
    $processCount = @($actions | Where-Object { $_.Action -in @('StopProcess', 'StopModuleHolder') -and $_.Result -eq 'Success' }).Count
    $vendorSucceededCount = @($actions | Where-Object {
        $_.Action -eq 'RunVendorUninstaller' -and $_.Result -eq 'Success'
    }).Count
    $vendorFailedCount = @($actions | Where-Object {
        $_.Action -eq 'RunVendorUninstaller' -and $_.Result -eq 'Failed'
    }).Count
    $vendorPendingCount = @($actions | Where-Object {
        $_.Action -eq 'RunVendorUninstaller' -and $_.Result -eq 'Pending'
    }).Count
    $skippedCount = @($actions | Where-Object { $_.Result -eq 'Skipped' }).Count
    $failedCount = @($actions | Where-Object { $_.Result -eq 'Failed' }).Count
    $pendingCount = @($actions | Where-Object { $_.Result -in @('Pending', 'PendingRemoval') }).Count
    $retryAttemptCount = @($actions | Where-Object { $_.Result -eq 'RetryRequired' }).Count
    $aclRepairAttemptCount = @($actions | Where-Object { $_.Action -eq 'RepairPathAcl' }).Count
    $aclRepairFailureCount = @($actions | Where-Object {
        $_.Action -eq 'RepairPathAcl' -and $_.Result -eq 'Failed'
    }).Count
    $unresolvedRetryCount = @($actions | Where-Object {
        $_.Action -in @('DeletePathRetry', 'DeletePathForceRetry') -and
        $_.Result -in @('Skipped', 'Failed')
    } | Select-Object -ExpandProperty Target -Unique).Count
    $accessDeniedPathTargetCount = $observedAccessDeniedPathTargets.Count
    $unresolvedPathTargetCount = $unresolvedPathTargets.Count
    $unmeasuredPathTargetCount = $unmeasuredPathTargets.Count
    $totalItemsRemoved = [int64]$filesRemoved + [int64]$directoriesRemoved + [int64]$serviceCount +
        [int64]$taskCount + [int64]$registryKeyCount + [int64]$registryValueCount
    $removalSummary = [pscustomobject]@{
        TotalItemsRemoved           = $totalItemsRemoved
        FilesRemoved                = $filesRemoved
        DirectoriesRemoved          = $directoriesRemoved
        LogicalBytesRemoved         = $bytesRemoved
        LogicalSizeRemoved          = Format-ByteSize $bytesRemoved
        PathTargetsRemoved          = $pathTargetsRemoved
        PartiallyCleanedPathTargets = $partiallyCleanedPathTargets
        ServicesRemoved             = $serviceCount
        ServicesPendingRemoval      = $servicePendingCount
        ScheduledTasksRemoved       = $taskCount
        RegistryKeysRemoved         = $registryKeyCount
        RegistryValuesRemoved       = $registryValueCount
        ProcessesStopped            = $processCount
        VendorUninstallersSucceeded = $vendorSucceededCount
        VendorUninstallersFailed    = $vendorFailedCount
        VendorUninstallersPending   = $vendorPendingCount
        SkippedActions              = $skippedCount
        FailedActions               = $failedCount
        PendingActions              = $pendingCount
        RetryAttempts               = $retryAttemptCount
        UnresolvedRetryTargets      = $unresolvedRetryCount
        AccessDeniedPathTargets     = $accessDeniedPathTargetCount
        AclRepairAttempts           = $aclRepairAttemptCount
        AclRepairFailures           = $aclRepairFailureCount
        UnresolvedPathTargets       = $unresolvedPathTargetCount
        PathAccountingComplete      = ($unmeasuredPathTargetCount -eq 0)
        UnmeasuredPathTargets       = $unmeasuredPathTargetCount
        PostVendorMutationBlocked  = [bool]$postVendorMutationBlocked
        ImmediateRescanComplete    = (-not $postVendorMutationBlocked)
        ImmediateRemainingConfirmed = $(if ($postVendorMutationBlocked) { $null } else { 0 })
        NoImmediateConfirmedFindings = $false
    }
    if ($null -ne $Summary) {
        $Summary.Clear()
        foreach ($property in $removalSummary.PSObject.Properties) {
            $Summary[$property.Name] = $property.Value
        }
    }

    return @($actions)
}

function Test-RemovalOutcomeRequiresAttention {
    param(
        [object]$Summary,
        [int]$RemainingConfirmed = 0
    )

    if ($RemainingConfirmed -gt 0 -or $null -eq $Summary) { return $true }

    if ($Summary -is [System.Collections.IDictionary]) {
        $propertyNames = @($Summary.Keys | ForEach-Object { [string]$_ })
        if ($propertyNames -notcontains 'PathAccountingComplete' -or
            $propertyNames -notcontains 'UnresolvedPathTargets' -or
            $propertyNames -notcontains 'AclRepairFailures' -or
            $propertyNames -notcontains 'FailedActions' -or
            $propertyNames -notcontains 'VendorUninstallersFailed' -or
            $propertyNames -notcontains 'VendorUninstallersPending' -or
            $propertyNames -notcontains 'ImmediateRescanComplete' -or
            $propertyNames -notcontains 'PostVendorMutationBlocked') {
            return $true
        }
        $pathAccountingComplete = [bool]$Summary['PathAccountingComplete']
        $unresolvedPathCount = [int]$Summary['UnresolvedPathTargets']
        $aclRepairFailureCount = [int]$Summary['AclRepairFailures']
        $failedActionCount = [int]$Summary['FailedActions']
        $vendorFailureCount = [int]$Summary['VendorUninstallersFailed']
        $vendorPendingCount = [int]$Summary['VendorUninstallersPending']
        $immediateRescanComplete = [bool]$Summary['ImmediateRescanComplete']
        $postVendorBlocked = [bool]$Summary['PostVendorMutationBlocked']
    }
    else {
        $propertyNames = @($Summary.PSObject.Properties.Name)
        if ($propertyNames -notcontains 'PathAccountingComplete' -or
            $propertyNames -notcontains 'UnresolvedPathTargets' -or
            $propertyNames -notcontains 'AclRepairFailures' -or
            $propertyNames -notcontains 'FailedActions' -or
            $propertyNames -notcontains 'VendorUninstallersFailed' -or
            $propertyNames -notcontains 'VendorUninstallersPending' -or
            $propertyNames -notcontains 'ImmediateRescanComplete' -or
            $propertyNames -notcontains 'PostVendorMutationBlocked') {
            return $true
        }
        $pathAccountingComplete = [bool]$Summary.PathAccountingComplete
        $unresolvedPathCount = [int]$Summary.UnresolvedPathTargets
        $aclRepairFailureCount = [int]$Summary.AclRepairFailures
        $failedActionCount = [int]$Summary.FailedActions
        $vendorFailureCount = [int]$Summary.VendorUninstallersFailed
        $vendorPendingCount = [int]$Summary.VendorUninstallersPending
        $immediateRescanComplete = [bool]$Summary.ImmediateRescanComplete
        $postVendorBlocked = [bool]$Summary.PostVendorMutationBlocked
    }

    return (-not $pathAccountingComplete -or $unresolvedPathCount -gt 0 -or
        $aclRepairFailureCount -gt 0 -or $failedActionCount -gt 0 -or
        $vendorFailureCount -gt 0 -or $vendorPendingCount -gt 0 -or
        -not $immediateRescanComplete -or $postVendorBlocked)
}

function Show-RemovalSummary {
    param([object]$Summary)

    if ($null -eq $Summary) { return }
    $qualifier = $(if ($Summary.PathAccountingComplete) { '' } else { 'At least ' })
    Write-Host ''
    Write-Host 'Removal summary:' -ForegroundColor Cyan
    Write-Host ("{0}total removed items: {1}" -f $qualifier, $Summary.TotalItemsRemoved)
    Write-Host ("Files removed: {0}; directories removed: {1}" -f $Summary.FilesRemoved, $Summary.DirectoriesRemoved)
    Write-Host ("Logical file content removed: {0} ({1} bytes); actual free-disk change can differ" -f `
        $Summary.LogicalSizeRemoved, $Summary.LogicalBytesRemoved)
    Write-Host ("Services removed: {0}; services pending restart/removal: {1}; scheduled tasks: {2}" -f `
        $Summary.ServicesRemoved, $Summary.ServicesPendingRemoval, $Summary.ScheduledTasksRemoved)
    Write-Host ("Registry keys: {0}; registry values: {1}; processes stopped: {2}" -f `
        $Summary.RegistryKeysRemoved, $Summary.RegistryValuesRemoved, $Summary.ProcessesStopped)
    Write-Host ("Skipped actions: {0}; failed actions: {1}; pending actions: {2}" -f `
        $Summary.SkippedActions, $Summary.FailedActions, $Summary.PendingActions)
    Write-Host ("Retry attempts: {0}; unresolved retry targets: {1}" -f `
        $Summary.RetryAttempts, $Summary.UnresolvedRetryTargets)
    $summaryPropertyNames = if ($Summary -is [System.Collections.IDictionary]) {
        @($Summary.Keys | ForEach-Object { [string]$_ })
    }
    else { @($Summary.PSObject.Properties.Name) }
    if ($summaryPropertyNames -contains 'AccessDeniedPathTargets') {
        Write-Host ("Access-denied path targets observed: {0}; ACL repair attempts: {1}; ACL repair failures: {2}" -f `
            $Summary.AccessDeniedPathTargets, $Summary.AclRepairAttempts, $Summary.AclRepairFailures)
        Write-Host ("Unresolved path targets: {0}" -f $Summary.UnresolvedPathTargets)
    }
    if ($summaryPropertyNames -contains 'VendorUninstallersSucceeded') {
        Write-Host ("Vendor uninstallers succeeded: {0}; failed: {1}; pending: {2}" -f `
            $Summary.VendorUninstallersSucceeded, $Summary.VendorUninstallersFailed, `
            $Summary.VendorUninstallersPending)
    }
    Write-Host ("Fully removed path targets: {0}; partially cleaned path targets: {1}" -f `
        $Summary.PathTargetsRemoved, $Summary.PartiallyCleanedPathTargets)
    if ($summaryPropertyNames -contains 'ApprovedConfirmed') {
        Write-Host ("Approved confirmed: {0}; eligible now: {1}; new since approval: {2}" -f `
            $Summary.ApprovedConfirmed, $Summary.EligibleApproved, $Summary.NewSinceApproval)
        Write-Host ("Missing since approval: {0}; no longer confirmed: {1}" -f `
            $Summary.MissingSinceApproval, $Summary.NoLongerConfirmed)
    }
    if ($summaryPropertyNames -contains 'ImmediateRescanComplete' -and -not $Summary.ImmediateRescanComplete) {
        Write-Warning 'Immediate remaining-state rescan was blocked. Findings are the last safe pre-mutation snapshot, not proof of current remaining state.'
    }
    else {
        Write-Host ("Immediate remaining confirmed findings: {0}; no immediate confirmed findings: {1}" -f `
            $Summary.ImmediateRemainingConfirmed, $Summary.NoImmediateConfirmedFindings)
    }
    Write-Host ("Path accounting complete: {0}; unmeasured path targets: {1}" -f `
        $Summary.PathAccountingComplete, $Summary.UnmeasuredPathTargets)
    if (-not $Summary.PathAccountingComplete) {
        Write-Warning ("{0} path target(s) could not be measured safely; totals above are minimum confirmed values." -f $Summary.UnmeasuredPathTargets)
    }
}

function Show-CleanupReportOutcome {
    param(
        [string]$Path,
        [string]$ExpectedApprovedReportHash,
        [string]$ExpectedOutcomeRunId
    )

    $normalPath = Get-NormalPath $Path
    if (-not $normalPath -or -not (Test-Path -LiteralPath $normalPath -PathType Leaf)) {
        throw "Cleanup outcome report was not found: $Path"
    }
    try {
        $bytes = [IO.File]::ReadAllBytes($normalPath)
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $report = $utf8.GetString($bytes) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Cleanup outcome report is not valid UTF-8 JSON: $normalPath. $($_.Exception.Message)"
    }
    $propertyNames = @($report.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'SchemaVersion' -or [int]$report.SchemaVersion -ne 2) {
        throw 'Cleanup outcome report must use SchemaVersion 2.'
    }
    foreach ($requiredName in @('Mode', 'Summary', 'Actions', 'Findings', 'ApprovedReportHash', 'OutcomeRunId')) {
        if ($propertyNames -notcontains $requiredName) {
            throw "Cleanup outcome report is missing $requiredName."
        }
    }
    if ([string]$report.Mode -cne 'Remove' -or $null -eq $report.Summary -or
        $null -eq $report.Actions -or $null -eq $report.Findings) {
        throw 'Cleanup outcome report does not contain a complete Remove result.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedApprovedReportHash)) {
        if ($ExpectedApprovedReportHash -notmatch '^[0-9a-fA-F]{64}$' -or
            -not ([string]$report.ApprovedReportHash).Equals(
                $ExpectedApprovedReportHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Cleanup outcome report does not match the approved Scan report.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedOutcomeRunId)) {
        if ($ExpectedOutcomeRunId -notmatch '^[0-9a-fA-F]{32}$' -or
            -not ([string]$report.OutcomeRunId).Equals(
                $ExpectedOutcomeRunId, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Cleanup outcome report does not match this removal run.'
        }
    }

    Write-Host ''
    Write-Host 'Removal actions:' -ForegroundColor Cyan
    $actionText = @($report.Actions) | Format-Table Time, Action, Target, Result, Detail -AutoSize -Wrap | Out-String
    if (-not [string]::IsNullOrWhiteSpace($actionText)) { Write-Host ($actionText.TrimEnd()) }
    if ($null -ne $report.Summary) { Show-RemovalSummary $report.Summary }
    Write-Host ''
    $reportSummaryPropertyNames = @($report.Summary.PSObject.Properties.Name)
    if ($reportSummaryPropertyNames -contains 'ImmediateRescanComplete' -and
        -not [bool]$report.Summary.ImmediateRescanComplete) {
        Write-Warning 'Findings below are the last safe pre-mutation snapshot, not proof of current remaining state.'
        Write-Host 'Last safe pre-mutation findings:' -ForegroundColor Cyan
    }
    else {
        Write-Host 'Remaining findings:' -ForegroundColor Cyan
    }
    if (@($report.Findings).Count -eq 0) {
        Write-Host 'No matching 360/Qihoo findings.' -ForegroundColor Green
    }
    else {
        $findingText = @($report.Findings) | Sort-Object Confidence, Kind, Name |
            Select-Object Confidence, Kind, Name, Target, Reason | Format-Table -AutoSize -Wrap | Out-String
        Write-Host ($findingText.TrimEnd())
    }
    Write-Host "Report: $normalPath" -ForegroundColor Cyan
    return $report
}

function Invoke-ElevatedCleanup {
    param(
        [string]$ScriptPath,
        [string]$ApprovedReport,
        [string]$ApprovedReportHash,
        [string]$OutcomeRunId,
        [string]$ReportPath,
        [bool]$IncludeBrowserProfiles = $false,
        [bool]$AllowExplorerRestart = $false,
        [bool]$ForceLockedTargets = $false,
        [bool]$IncludeIdentityInReport = $false
    )

    $argumentLine = New-ElevatedCleanupArgumentLine -ScriptPath $ScriptPath `
        -ApprovedReport $ApprovedReport -ApprovedReportHash $ApprovedReportHash `
        -OutcomeRunId $OutcomeRunId -ReportPath $ReportPath `
        -IncludeBrowserProfiles:$IncludeBrowserProfiles -AllowExplorerRestart:$AllowExplorerRestart `
        -ForceLockedTargets:$ForceLockedTargets -IncludeIdentityInReport:$IncludeIdentityInReport
    try {
        $process = Start-360CleanupElevatedProcess -FilePath 'powershell.exe' -ArgumentLine $argumentLine
        if ($null -eq $process -or @($process.PSObject.Properties.Name) -notcontains 'ExitCode') {
            throw 'The elevated cleanup process did not return an exit code.'
        }
        $childExitCode = [int]$process.ExitCode
    }
    catch {
        Write-Error ('Cleanup elevation was cancelled or failed. No removal success is being reported. ' +
            $_.Exception.Message) -ErrorAction Continue
        return 5
    }

    $outcomeDisplayed = $false
    if (Test-Path -LiteralPath $ReportPath -PathType Leaf) {
        try {
            Show-CleanupReportOutcome -Path $ReportPath -ExpectedApprovedReportHash $ApprovedReportHash `
                -ExpectedOutcomeRunId $OutcomeRunId | Out-Null
            $outcomeDisplayed = $true
        }
        catch {
            Write-Warning ('The elevated cleanup exited, but its outcome report could not be displayed. ' +
                $_.Exception.Message)
        }
    }
    else {
        Write-Warning 'The elevated cleanup did not create an outcome report.'
    }
    if ($childExitCode -eq 0 -and -not $outcomeDisplayed) {
        Write-Error 'The elevated cleanup returned success without a valid bound outcome report.' -ErrorAction Continue
        return 6
    }
    return $childExitCode
}

function Invoke-360CleanupRemoveElevationBoundary {
    param(
        [string]$ScriptPath,
        [string]$ApprovedReport,
        [string]$ApprovedReportHash,
        [string]$OutcomeRunId,
        [string]$ReportPath,
        [bool]$InternalElevatedChild = $false,
        [bool]$IncludeBrowserProfiles = $false,
        [bool]$AllowExplorerRestart = $false,
        [bool]$ForceLockedTargets = $false,
        [bool]$IncludeIdentityInReport = $false
    )

    $isAdministrator = Test-IsAdministrator
    if ($InternalElevatedChild -and -not $isAdministrator) {
        throw 'The elevated cleanup child is not running as an administrator.'
    }
    if ($isAdministrator) {
        return [pscustomobject]@{ Handled = $false; ExitCode = 0 }
    }

    $elevatedExitCode = Invoke-ElevatedCleanup -ScriptPath $ScriptPath `
        -ApprovedReport $ApprovedReport -ApprovedReportHash $ApprovedReportHash `
        -OutcomeRunId $OutcomeRunId -ReportPath $ReportPath `
        -IncludeBrowserProfiles:$IncludeBrowserProfiles -AllowExplorerRestart:$AllowExplorerRestart `
        -ForceLockedTargets:$ForceLockedTargets -IncludeIdentityInReport:$IncludeIdentityInReport
    return [pscustomobject]@{ Handled = $true; ExitCode = [int]$elevatedExitCode }
}

if ($InternalTestLibraryOnly) {
    if ($env:WINDOWS_360_CLEANER_TEST_MODE -cne 'ISOLATED-SAFETY-TEST') {
        throw 'InternalTestLibraryOnly is reserved for the bundled isolated safety suite.'
    }
    return
}

if ($InternalElevatedChild -and $Mode -ne 'Remove') {
    throw 'InternalElevatedChild is valid only for Remove mode.'
}

if ($OfflineWindowsRoot -and $Mode -eq 'Remove') {
    throw 'OfflineWindowsRoot is scan-only. Remove from an offline Windows installation requires a separate, explicit workflow.'
}

$approvedInput = $null
if ($Mode -eq 'Remove') {
    if ([string]::IsNullOrWhiteSpace($ApprovedReport)) {
        throw 'Removal requires -ApprovedReport pointing to the reviewed SchemaVersion 2 Scan report.'
    }
    if (-not $ConfirmRemoval) {
        throw 'Removal requires -ConfirmRemoval after the user has reviewed the scan.'
    }
    if ($ConfirmationPhrase -cne 'REMOVE-CONFIRMED-360') {
        throw 'Removal requires the exact phrase: -ConfirmationPhrase REMOVE-CONFIRMED-360'
    }
    if ($IncludeBrowserProfiles -and $BrowserProfileConfirmation -cne 'DELETE-360-BROWSER-DATA') {
        throw 'Deleting browser profiles requires the separate exact phrase: -BrowserProfileConfirmation DELETE-360-BROWSER-DATA'
    }
    if ($InternalElevatedChild -and [string]::IsNullOrWhiteSpace($ApprovedReportHash)) {
        throw 'The elevated cleanup child requires ApprovedReportHash.'
    }
    if ($InternalElevatedChild) {
        if ($OutcomeRunId -notmatch '^[0-9a-fA-F]{32}$') {
            throw 'The elevated cleanup child requires a valid OutcomeRunId.'
        }
    }
    else {
        $OutcomeRunId = [Guid]::NewGuid().ToString('N')
    }

    $approvedInput = Read-ApprovedCleanupReport -Path $ApprovedReport -ExpectedHash $ApprovedReportHash
    $ApprovedReport = $approvedInput.Path
    $ApprovedReportHash = $approvedInput.Hash
    if (-not $InternalElevatedChild) {
        Assert-CleanupApprovalContextMatchesCaller -ApprovalContext $approvedInput.Report.ApprovalContext
    }
    Set-CleanupSourceContext -ApprovalContext $approvedInput.Report.ApprovalContext

    $approvedBrowserProfiles = [bool]$approvedInput.Report.ApprovalContext.Options.IncludeBrowserProfiles
    if ($IncludeBrowserProfiles -and -not $approvedBrowserProfiles) {
        throw 'IncludeBrowserProfiles requires a Scan report created with the same option.'
    }
}

if (-not $ReportPath) {
    $reportDirectory = $script:KnownFolders.Desktop
    if (-not $reportDirectory) { $reportDirectory = $script:KnownFolders.Temp }
    $ReportPath = Join-Path $reportDirectory ('360-cleanup-report-{0:yyyyMMdd-HHmmss}-{1}.json' -f (Get-Date), ([Guid]::NewGuid().ToString('N').Substring(0, 8)))
}
$ReportPath = Assert-SafeReportPath $ReportPath

if ($Mode -eq 'Remove') {
    $elevationBoundary = Invoke-360CleanupRemoveElevationBoundary -ScriptPath $PSCommandPath `
        -ApprovedReport $ApprovedReport -ApprovedReportHash $ApprovedReportHash `
        -OutcomeRunId $OutcomeRunId -ReportPath $ReportPath `
        -InternalElevatedChild:$InternalElevatedChild -IncludeBrowserProfiles:$IncludeBrowserProfiles `
        -AllowExplorerRestart:$AllowExplorerRestart -ForceLockedTargets:$ForceLockedTargets `
        -IncludeIdentityInReport:$IncludeIdentityInReport
    if ($elevationBoundary.Handled) {
        exit $elevationBoundary.ExitCode
    }
}

Write-Host "Windows 360 Cleaner - $Mode" -ForegroundColor Cyan
$initialFindings = @(Get-360Findings -OfflineRoot $OfflineWindowsRoot -IncludeProfiles:$IncludeBrowserProfiles)
Show-Findings $initialFindings

if ($Mode -eq 'Scan') {
    $approvalContext = New-CleanupApprovalContext -IncludeBrowserProfiles:$IncludeBrowserProfiles
    Save-CleanupReport -Path $ReportPath -RunMode $Mode -Findings $initialFindings -Actions @() `
        -ApprovalContext $approvalContext -IncludeIdentity:$IncludeIdentityInReport
    Write-Host "Report: $ReportPath" -ForegroundColor Cyan
    exit 0
}

if ($Mode -eq 'Verify') {
    Save-CleanupReport -Path $ReportPath -RunMode $Mode -Findings $initialFindings -Actions @() -IncludeIdentity:$IncludeIdentityInReport
    $confirmedCount = @($initialFindings | Where-Object { $_.Confidence -eq 'Confirmed' }).Count
    if ($confirmedCount -gt 0) {
        Write-Warning "$confirmedCount confirmed finding(s) remain. Report: $ReportPath"
        exit 2
    }
    Write-Host "Verification passed. Report: $ReportPath" -ForegroundColor Green
    exit 0
}

$approvalComparison = Compare-ApprovedCleanupFindings -Approved @($approvedInput.Report.Findings) `
    -Current $initialFindings -SID ([string]$approvedInput.Report.ApprovalContext.UserSid)
$removalSummary = [ordered]@{}
$actions = @(Remove-ConfirmedFindings -Findings @($approvalComparison.Eligible) -AllowExplorerRestart:$AllowExplorerRestart `
    -ForceLockedTargets:$ForceLockedTargets -Summary $removalSummary)
$remainingFindings = @()
$remainingConfirmed = $null
if ([bool]$removalSummary.PostVendorMutationBlocked) {
    $remainingFindings = @($initialFindings)
    $removalSummary['ImmediateRescanComplete'] = $false
}
else {
    $remainingFindings = @(Get-360Findings -IncludeProfiles:$IncludeBrowserProfiles)
    $remainingConfirmed = @($remainingFindings | Where-Object { $_.Confidence -eq 'Confirmed' }).Count
    $removalSummary['ImmediateRescanComplete'] = $true
}
$removalSummary['ApprovedConfirmed'] = [int]$approvalComparison.ApprovedCount
$removalSummary['EligibleApproved'] = @($approvalComparison.Eligible).Count
$removalSummary['NewSinceApproval'] = @($approvalComparison.NewSinceApproval).Count
$removalSummary['MissingSinceApproval'] = @($approvalComparison.MissingSinceApproval).Count
$removalSummary['NoLongerConfirmed'] = @($approvalComparison.NoLongerConfirmed).Count
$removalSummary['ImmediateRemainingConfirmed'] = $remainingConfirmed
$removalSummary['NoImmediateConfirmedFindings'] = ($null -ne $remainingConfirmed -and $remainingConfirmed -eq 0)
Save-CleanupReport -Path $ReportPath -RunMode $Mode -Findings $remainingFindings -Actions $actions `
    -Summary $removalSummary -ApprovalContext $approvedInput.Report.ApprovalContext `
    -ApprovedReportHash $ApprovedReportHash -OutcomeRunId $OutcomeRunId `
    -IncludeIdentity:$IncludeIdentityInReport

Write-Host ''
Write-Host 'Removal actions:' -ForegroundColor Cyan
$actions | Format-Table Time, Action, Target, Result, Detail -AutoSize -Wrap
Show-RemovalSummary $removalSummary
Write-Host ''
if ([bool]$removalSummary.ImmediateRescanComplete) {
    Write-Host 'Remaining findings:' -ForegroundColor Cyan
}
else {
    Write-Warning 'Findings below are the last safe pre-mutation snapshot, not proof of current remaining state.'
    Write-Host 'Last safe pre-mutation findings:' -ForegroundColor Cyan
}
Show-Findings $remainingFindings
Write-Host "Report: $ReportPath" -ForegroundColor Cyan

if (Test-RemovalOutcomeRequiresAttention -Summary $removalSummary -RemainingConfirmed $remainingConfirmed) {
    $remainingConfirmedText = if ([bool]$removalSummary.ImmediateRescanComplete) {
        [string]$remainingConfirmed
    }
    else { 'unknown (immediate rescan blocked)' }
    $attentionMessage = ("Cleanup requires attention: {0} confirmed finding(s) remain, {1} path target(s) are unresolved, " +
        "{2} ACL repair(s) failed, and path accounting complete is {3}. Reboot and run Verify; do not broaden deletion without review.") -f `
        $remainingConfirmedText, $removalSummary.UnresolvedPathTargets, $removalSummary.AclRepairFailures,
        $removalSummary.PathAccountingComplete
    Write-Warning $attentionMessage
    exit 2
}

Write-Host 'Approved targets that were still confirmed were processed. Restart Windows once, then run Verify.' -ForegroundColor Green
exit 0
