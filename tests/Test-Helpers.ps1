#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function New-TestRun {
    param([Parameter(Mandatory = $true)][string]$Name)

    [pscustomobject]@{
        Name     = $Name
        Passed   = 0
        Failed   = 0
        Failures = New-Object System.Collections.ArrayList
    }
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory = $true)][object]$Run,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Test
    )

    try {
        & $Test
        $Run.Passed++
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $Run.Failed++
        [void]$Run.Failures.Add([pscustomobject]@{
            Name    = $Name
            Message = $_.Exception.Message
        })
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Complete-TestRun {
    param([Parameter(Mandatory = $true)][object]$Run)

    if ($Run.Failed -gt 0) {
        $details = @($Run.Failures | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Message }) -join [Environment]::NewLine
        throw ("{0}: {1} passed, {2} failed.{3}{4}" -f `
            $Run.Name, $Run.Passed, $Run.Failed, [Environment]::NewLine, $details)
    }

    Write-Host ("{0}: {1} test(s) passed." -f $Run.Name, $Run.Passed) -ForegroundColor Cyan
}

function Assert-TestTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-TestFalse {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Condition) { throw $Message }
}

function Assert-TestEqual {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Expected,
        [Parameter(Mandatory = $true)][AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not [object]::Equals($Expected, $Actual)) {
        throw ("{0} Expected: <{1}>. Actual: <{2}>." -f $Message, $Expected, $Actual)
    }
}

function Assert-TestNull {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($null -ne $Actual) { throw $Message }
}

function Assert-TestNotNull {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($null -eq $Actual) { throw $Message }
}

function Assert-TestThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Operation,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$ExpectedMessagePattern
    )

    $caught = $null
    try { & $Operation }
    catch { $caught = $_ }

    if ($null -eq $caught) { throw $Message }
    if ($ExpectedMessagePattern -and $caught.Exception.Message -notmatch $ExpectedMessagePattern) {
        throw ("{0} Exception did not match <{1}>. Actual: <{2}>." -f `
            $Message, $ExpectedMessagePattern, $caught.Exception.Message)
    }
}

function Assert-TestSequenceEqual {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Expected,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected.Count -ne $Actual.Count) {
        throw ("{0} Expected {1} item(s), got {2}." -f $Message, $Expected.Count, $Actual.Count)
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if (-not [object]::Equals($Expected[$index], $Actual[$index])) {
            throw ("{0} Item {1} differs. Expected: <{2}>. Actual: <{3}>." -f `
                $Message, $index, $Expected[$index], $Actual[$index])
        }
    }
}

function New-TestDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('windows-360-cleaner-tests-{0}' -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Remove-TestDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $leaf = Split-Path -Leaf $fullPath
    if (-not $fullPath.StartsWith($tempRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notmatch '^windows-360-cleaner-tests-[0-9a-f]{32}$') {
        throw "Refusing to remove a path outside the isolated test directory contract: $fullPath"
    }

    if (Test-Path -LiteralPath $fullPath) {
        Remove-Item -LiteralPath $fullPath -Recurse -Force
    }
}

function New-Fake360CleanupRuntimeProvider {
    param(
        [string[]]$ExistingRegistryPaths = @(),
        [string[]]$ProductEvidencePaths = @(),
        [string[]]$TrustedDuohuiVendorPaths = @(),
        [hashtable]$RegistrySubKeys = @{},
        [hashtable]$RegistryValues = @{},
        [hashtable]$PathItems = @{},
        [hashtable]$PathChildren = @{},
        [hashtable]$PathRemovals = @{},
        [hashtable]$PathAclRepairs = @{},
        [switch]$UseRealPathReads,
        [AllowEmptyCollection()][object[]]$ScheduledTasks = @(),
        [AllowEmptyCollection()][object[]]$Services = @(),
        [AllowEmptyCollection()][object[]]$Processes = @(),
        [bool]$IsAdministrator = $false,
        [int]$ElevatedExitCode = 0,
        [AllowNull()][object]$VendorUninstallerResult = $null,
        [AllowNull()][scriptblock]$BeforeVendorUninstallerStart = $null
    )

    if ($null -eq $VendorUninstallerResult) {
        $VendorUninstallerResult = [pscustomobject]@{
            Result   = 'Success'
            ExitCode = 0
            Detail   = 'Fake vendor uninstaller completed.'
        }
    }

    $calls = New-Object System.Collections.ArrayList
    $registryPaths = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $ExistingRegistryPaths) { [void]$registryPaths.Add($path) }
    foreach ($path in $RegistrySubKeys.Keys) { [void]$registryPaths.Add([string]$path) }
    foreach ($path in $RegistryValues.Keys) { [void]$registryPaths.Add([string]$path) }
    $productEvidence = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $ProductEvidencePaths) { [void]$productEvidence.Add($path) }
    $trustedDuohuiVendors = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $TrustedDuohuiVendorPaths) { [void]$trustedDuohuiVendors.Add($path) }

    $context = [pscustomobject]@{
        Calls                 = $calls
        RegistryPaths         = $registryPaths
        ProductEvidencePaths  = $productEvidence
        TrustedDuohuiVendorPaths = $trustedDuohuiVendors
        RegistrySubKeysByPath = $RegistrySubKeys
        RegistryValuesByPath  = $RegistryValues
        PathItemsByPath       = $PathItems
        PathChildrenByPath    = $PathChildren
        PathRemovalsByPath    = $PathRemovals
        PathAclRepairsByPath  = $PathAclRepairs
        RealPathReadsEnabled  = [bool]$UseRealPathReads
        ScheduledTaskItems    = @($ScheduledTasks)
        ServiceItems          = @($Services)
        ProcessItems          = @($Processes)
        AdministratorResult   = $IsAdministrator
        ElevatedExitCode      = $ElevatedExitCode
        VendorUninstallerResult = $VendorUninstallerResult
        BeforeVendorUninstallerStart = $BeforeVendorUninstallerStart
        VendorUninstallerStartedCallbacks = 0
    }

    $provider = @{
        Is360File = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'Is360File'
                Arguments = @($Path)
            })
            return $Context.ProductEvidencePaths.Contains($Path)
        }
        IsTrustedDuohuiVendorFile = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'IsTrustedDuohuiVendorFile'
                Arguments = @($Path)
            })
            return $Context.TrustedDuohuiVendorPaths.Contains($Path)
        }
        PathItem = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'PathItem'
                Arguments = @($Path)
            })
            if ($Context.PathItemsByPath.ContainsKey($Path)) {
                $behavior = $Context.PathItemsByPath[$Path]
                if ($behavior -is [scriptblock]) { return (& $behavior $Context $Path) }
                if ($behavior -is [Exception]) { throw $behavior }
                if ($null -eq $behavior) {
                    throw (New-Object System.IO.FileNotFoundException -ArgumentList @('The fake path item is absent.', $Path))
                }
                return $behavior
            }
            if ($Context.RealPathReadsEnabled) {
                return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            throw (New-Object System.IO.FileNotFoundException -ArgumentList @('The fake path item is absent.', $Path))
        }
        PathChildren = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'PathChildren'
                Arguments = @($Path)
            })
            if ($Context.PathChildrenByPath.ContainsKey($Path)) {
                $behavior = $Context.PathChildrenByPath[$Path]
                if ($behavior -is [scriptblock]) { return @(& $behavior $Context $Path) }
                if ($behavior -is [Exception]) { throw $behavior }
                return @($behavior)
            }
            if ($Context.RealPathReadsEnabled) {
                return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
            }
            return @()
        }
        RemovePath = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'RemovePath'
                Arguments = @($Path)
            })
            if (-not $Context.PathRemovalsByPath.ContainsKey($Path)) {
                throw "No fake path-removal behavior was configured for: $Path"
            }
            $behavior = $Context.PathRemovalsByPath[$Path]
            if ($behavior -is [scriptblock]) { return (& $behavior $Context $Path) }
            if ($behavior -is [Exception]) { throw $behavior }
            return $behavior
        }
        RepairPathAcl = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'RepairPathAcl'
                Arguments = @($Path)
            })
            if (-not $Context.PathAclRepairsByPath.ContainsKey($Path)) {
                throw "No fake ACL-repair behavior was configured for: $Path"
            }
            $behavior = $Context.PathAclRepairsByPath[$Path]
            if ($behavior -is [scriptblock]) { return (& $behavior $Context $Path) }
            if ($behavior -is [Exception]) { throw $behavior }
            return $behavior
        }
        RegistryPathExists = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'RegistryPathExists'
                Arguments = @($Path)
            })
            return $Context.RegistryPaths.Contains($Path)
        }
        RegistrySubKeys = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'RegistrySubKeys'
                Arguments = @($Path)
            })
            if ($Context.RegistrySubKeysByPath.ContainsKey($Path)) {
                return @($Context.RegistrySubKeysByPath[$Path])
            }
            return @()
        }
        RegistryValues = {
            param($Context, [string]$Path)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'RegistryValues'
                Arguments = @($Path)
            })
            if ($Context.RegistryValuesByPath.ContainsKey($Path)) {
                $behavior = $Context.RegistryValuesByPath[$Path]
                if ($behavior -is [scriptblock]) { return (& $behavior $Context $Path) }
                if ($behavior -is [Exception]) { throw $behavior }
                return $behavior
            }
            return $null
        }
        ScheduledTasks = {
            param($Context)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'ScheduledTasks'
                Arguments = @()
            })
            return @($Context.ScheduledTaskItems)
        }
        Services = {
            param($Context)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'Services'
                Arguments = @()
            })
            return @($Context.ServiceItems)
        }
        Processes = {
            param($Context)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'Processes'
                Arguments = @()
            })
            return @($Context.ProcessItems)
        }
        IsAdministrator = {
            param($Context)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'IsAdministrator'
                Arguments = @()
            })
            return $Context.AdministratorResult
        }
        StartElevatedProcess = {
            param($Context, [string]$FilePath, [string]$ArgumentLine)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'StartElevatedProcess'
                Arguments = @($FilePath, $ArgumentLine)
            })
            return [pscustomobject]@{ ExitCode = $Context.ElevatedExitCode }
        }
        StartVendorUninstaller = {
            param(
                $Context,
                [string]$FilePath,
                [string]$ArgumentLine,
                [int]$TimeoutMilliseconds,
                [scriptblock]$OnStarted
            )
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'StartVendorUninstaller'
                Arguments = @($FilePath, $ArgumentLine, $TimeoutMilliseconds)
            })
            if ($null -ne $Context.BeforeVendorUninstallerStart) {
                $beforeStart = $Context.BeforeVendorUninstallerStart
                & $beforeStart $Context $FilePath $ArgumentLine $TimeoutMilliseconds
            }
            & $OnStarted
            $Context.VendorUninstallerStartedCallbacks++
            return $Context.VendorUninstallerResult
        }
        StopProcess = {
            param($Context, [int]$ProcessId, [string]$ExpectedExecutable)
            [void]$Context.Calls.Add([pscustomobject]@{
                Operation = 'StopProcess'
                Arguments = @($ProcessId, $ExpectedExecutable)
            })
            return [pscustomobject]@{
                Target = ('fixture ({0})' -f $ProcessId)
                Result = 'Success'
                Detail = $ExpectedExecutable
            }
        }
    }

    return [pscustomobject]@{
        Provider = $provider
        Context  = $context
        Calls    = $calls
    }
}

function Get-Fake360CleanupCalls {
    param(
        [Parameter(Mandatory = $true)][object]$Fake,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    return @($Fake.Calls | Where-Object { $_.Operation -eq $Operation })
}

function Assert-TestPowerShellFileContract {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    Assert-TestTrue ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) `
        "PowerShell 5.1 compatibility requires a UTF-8 BOM: $Path"

    for ($index = 3; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 0x0A -and ($index -eq 0 -or $bytes[$index - 1] -ne 0x0D)) {
            throw "PowerShell files must use CRLF line endings: $Path"
        }
        if ($bytes[$index] -eq 0x0D -and ($index + 1 -ge $bytes.Length -or $bytes[$index + 1] -ne 0x0A)) {
            throw "PowerShell files must use CRLF line endings: $Path"
        }
    }

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        $details = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell parser validation failed for ${Path}: $details"
    }
}
