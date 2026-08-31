#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Scan', 'Remove', 'Verify')]
    [string]$Mode = 'Scan',

    [switch]$ConfirmRemoval,

    [string]$OfflineWindowsRoot,

    [string]$ReportPath
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

function Get-CommandExecutable {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $expanded = [Environment]::ExpandEnvironmentVariables($CommandLine.Trim())
    if ($expanded.StartsWith('"')) {
        $end = $expanded.IndexOf('"', 1)
        if ($end -gt 1) { return Get-NormalPath $expanded.Substring(1, $end - 1) }
    }

    $match = [regex]::Match($expanded, '^(.*?\.(?:exe|com|bat|cmd|scr|dll|sys))(?=\s|$)', 'IgnoreCase')
    if ($match.Success) { return Get-NormalPath $match.Groups[1].Value }
    return $null
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

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $version = $item.VersionInfo
        $metadata = '{0} {1} {2} {3}' -f $version.CompanyName, $version.ProductName, $version.FileDescription, $version.OriginalFilename
        $signer = Get-SignerSubject $Path
        return ($metadata -match '(?i)360\.cn|Qihoo|Qihu|奇虎|360安全|360软件管家|多绘屏保') -or
            ($signer -match '(?i)Beijing Qihu Technology|Qihoo|奇虎')
    }
    catch {
        return $false
    }
}

function Test-DirectoryHasNames {
    param(
        [string]$Path,
        [string[]]$Names,
        [int]$Minimum = 1
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $hits = 0
    try {
        Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if ($Names -contains $_.Name) { $hits++ }
        }
    }
    catch {}
    return $hits -ge $Minimum
}

function Test-DuohuiEvidence {
    param([string]$Path)

    return Test-DirectoryHasNames $Path @(
        'duohuipingbao.exe', 'huabaosetup.exe', '360hb_tmp',
        'qcnethelp64.dll', 'xhqcnethelp64.dll'
    ) 1
}

function Test-SoftMgrEvidence {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $executables = @(Get-ChildItem -LiteralPath $Path -Filter 'softmgrsvr.exe' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($file in $executables) {
        if (Test-Is360File $file.FullName) { return $true }
    }

    return Test-DirectoryHasNames $Path @('360Base.dll', '360Conf.dll', '360NetBase.dll', '360Util.dll') 2
}

function Test-GreenCoreEvidence {
    param([string]$Path)
    return Test-DirectoryHasNames $Path @('360greencore.exe') 1
}

function New-Finding {
    param(
        [string]$Kind,
        [string]$Name,
        [string]$Target,
        [ValidateSet('Confirmed', 'ReviewOnly')]
        [string]$Confidence,
        [string]$Reason,
        [ValidateSet('Path', 'RegistryKey', 'RegistryValue', 'Service', 'Task', 'Process', 'None')]
        [string]$RemovalType = 'None',
        [string]$ValueName = '',
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
    param([string]$OfflineRoot)

    $findings = New-Object System.Collections.ArrayList
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $roamingAppData = [Environment]::GetEnvironmentVariable('APPDATA')
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $programData = [Environment]::GetEnvironmentVariable('ProgramData')
    $tempRoot = [IO.Path]::GetTempPath().TrimEnd('\')

    $exactPaths = @()
    if ($programFiles) { $exactPaths += @{ Name = '360 Program Files'; Path = (Join-Path $programFiles '360'); Confirm = $true; Reason = 'Exact vendor product directory.' } }
    if ($programFilesX86) { $exactPaths += @{ Name = '360 Program Files (x86)'; Path = (Join-Path $programFilesX86 '360'); Confirm = $true; Reason = 'Exact vendor product directory.' } }
    if ($programData) {
        $exactPaths += @{ Name = '360 ProgramData'; Path = (Join-Path $programData '360'); Confirm = $true; Reason = 'Exact vendor data directory.' }
        $exactPaths += @{ Name = '360Safe ProgramData'; Path = (Join-Path $programData '360safe'); Confirm = $true; Reason = 'Exact 360Safe data directory.' }
    }
    if ($localAppData) {
        $exactPaths += @{ Name = '360Chrome'; Path = (Join-Path $localAppData '360Chrome'); Confirm = $true; Reason = 'Exact 360 browser data directory.' }
        $exactPaths += @{ Name = 'Duohui screen saver'; Path = (Join-Path $localAppData 'dhpingbao'); Confirm = 'Duohui'; Reason = 'Known duohuipingbao installation path.' }
    }
    if ($roamingAppData) {
        foreach ($name in @('360se6', '360browser', '360Safe', '360GameAssistant', '360huabao', '360DrvMgrScrSaver')) {
            $exactPaths += @{ Name = $name; Path = (Join-Path $roamingAppData $name); Confirm = $true; Reason = 'Exact current-user 360 product path.' }
        }
        $exactPaths += @{ Name = 'GreenCore'; Path = (Join-Path $roamingAppData 'greencore'); Confirm = 'GreenCore'; Reason = 'GreenCore cache requires a 360greencore marker.' }
        $exactPaths += @{ Name = 'GreenCore7z'; Path = (Join-Path $roamingAppData 'GreenCore7z'); Confirm = 'GreenCore'; Reason = 'GreenCore archive cache requires a 360 marker.' }
    }
    if ($tempRoot) {
        $exactPaths += @{ Name = 'Duohui temporary package'; Path = (Join-Path $tempRoot 'duohuipingbao'); Confirm = 'Duohui'; Reason = 'Known duohuipingbao staging path.' }
        $exactPaths += @{ Name = 'Huabao temporary package'; Path = (Join-Path $tempRoot 'huabao_tmp'); Confirm = 'Duohui'; Reason = 'Known Huabao installer staging path.' }
        $exactPaths += @{ Name = '360 Game Assistant temporary files'; Path = (Join-Path $tempRoot '360gameassistantYyb'); Confirm = $true; Reason = 'Exact temporary component path.' }
        $exactPaths += @{ Name = '360 unpack temporary files'; Path = (Join-Path $tempRoot '360UnPackTmp64'); Confirm = $true; Reason = 'Exact temporary component path.' }
    }

    foreach ($candidate in $exactPaths) {
        if (-not (Test-Path -LiteralPath $candidate.Path)) { continue }
        $confirmed = $candidate.Confirm -eq $true
        if ($candidate.Confirm -eq 'Duohui') { $confirmed = Test-DuohuiEvidence $candidate.Path }
        if ($candidate.Confirm -eq 'GreenCore') { $confirmed = Test-GreenCoreEvidence $candidate.Path }
        Add-Finding $findings (New-Finding -Kind 'Path' -Name $candidate.Name -Target (Get-NormalPath $candidate.Path) `
            -Confidence $(if ($confirmed) { 'Confirmed' } else { 'ReviewOnly' }) `
            -Reason $(if ($confirmed) { $candidate.Reason } else { $candidate.Reason + ' Expected payload marker was not found.' }) `
            -RemovalType $(if ($confirmed) { 'Path' } else { 'None' }))
    }

    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot)) {
        $tempFiles = @()
        $tempFiles += @(Get-ChildItem -LiteralPath $tempRoot -File -Filter '360greencore.cab' -ErrorAction SilentlyContinue)
        $tempFiles += @(Get-ChildItem -LiteralPath $tempRoot -File -Filter '360se*.cab' -ErrorAction SilentlyContinue)
        foreach ($file in $tempFiles | Sort-Object FullName -Unique) {
            Add-Finding $findings (New-Finding -Kind 'Path' -Name '360 temporary package' -Target $file.FullName `
                -Confidence 'Confirmed' -Reason 'Exact 360 temporary CAB package pattern.' -RemovalType 'Path')
        }
    }

    $toolboxRoot = if ($localAppData) { Join-Path $localAppData 'winToolBox' } else { $null }
    $toolboxConfirmed = $false
    $softMgrRoots = @()
    if ($toolboxRoot -and (Test-Path -LiteralPath (Join-Path $toolboxRoot 'Tools'))) {
        $softMgrRoots = @(Get-ChildItem -LiteralPath (Join-Path $toolboxRoot 'Tools') -Directory -Filter 'SoftMgr*' -ErrorAction SilentlyContinue)
        foreach ($softMgr in $softMgrRoots) {
            if (Test-SoftMgrEvidence $softMgr.FullName) {
                $toolboxConfirmed = $true
                Add-Finding $findings (New-Finding -Kind 'Path' -Name '360 SoftMgr inside Aolande/Huajun winToolBox' `
                    -Target $softMgr.FullName -Confidence 'Confirmed' `
                    -Reason 'SoftMgr subtree contains 360-signed metadata or multiple 360 DLL markers; winToolBox itself is third-party.' `
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
            if (Test-Path -LiteralPath $updater -PathType Leaf) {
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
            $confirmed = (Test-SoftMgrEvidence $directory.FullName) -or $toolboxConfirmed
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

    $confirmedRoots = Get-ConfirmedPathRoots @($findings)

    $uninstallRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            $displayName = [string](Get-PropertyValue $properties 'DisplayName')
            $publisher = [string](Get-PropertyValue $properties 'Publisher')
            if (-not ($displayName -match '(?i)^(360|Qihoo)|360安全|360杀毒|360浏览|360极速|360软件管家|360压缩|360驱动|360游戏|360桌面|360壁纸|360画报|多绘屏保' -or
                $publisher -match '(?i)360\.cn|360安全中心|Qihoo|Qihu|奇虎')) { continue }

            $location = Get-NormalPath ([string](Get-PropertyValue $properties 'InstallLocation'))
            $underConfirmed = $false
            foreach ($confirmedRoot in $confirmedRoots) {
                if ($location -and (Test-IsUnderPath $location $confirmedRoot)) { $underConfirmed = $true; break }
            }
            $orphaned = -not $location -or -not (Test-Path -LiteralPath $location)
            $confirmedRecord = $orphaned -or $underConfirmed
            $reason = if ($orphaned) { '360-family uninstall record points to a missing install location.' }
                elseif ($underConfirmed) { 'Uninstall record points under a confirmed target path.' }
                else { '360-family product record has a live install location; prefer its vendor uninstaller first.' }
            Add-Finding $findings (New-Finding -Kind 'InstalledProduct' -Name $displayName -Target $key.PSPath `
                -Confidence $(if ($confirmedRecord) { 'Confirmed' } else { 'ReviewOnly' }) `
                -Reason $reason -RemovalType $(if ($confirmedRecord) { 'RegistryKey' } else { 'None' }))
        }
    }

    $confirmedRoots = Get-ConfirmedPathRoots @($findings)

    $runRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($runRoot in $runRoots) {
        if (-not (Test-Path -LiteralPath $runRoot)) { continue }
        $properties = Get-ItemProperty -LiteralPath $runRoot -ErrorAction SilentlyContinue
        foreach ($property in $properties.PSObject.Properties) {
            if ($property.Name -match '^PS') { continue }
            $executable = Get-CommandExecutable ([string]$property.Value)
            $matchedRoot = $null
            foreach ($confirmedRoot in $confirmedRoots) {
                if ($executable -and (Test-IsUnderPath $executable $confirmedRoot)) { $matchedRoot = $confirmedRoot; break }
            }
            if ($matchedRoot) {
                Add-Finding $findings (New-Finding -Kind 'Startup' -Name $property.Name -Target $runRoot `
                    -Confidence 'Confirmed' -Reason ('Startup executable is under confirmed target: ' + $matchedRoot) `
                    -RemovalType 'RegistryValue' -ValueName $property.Name)
            }
        }
    }

    $desktopKey = 'HKCU:\Control Panel\Desktop'
    if (Test-Path -LiteralPath $desktopKey) {
        $desktop = Get-ItemProperty -LiteralPath $desktopKey -ErrorAction SilentlyContinue
        $screenSaver = Get-NormalPath ([string](Get-PropertyValue $desktop 'SCRNSAVE.EXE'))
        foreach ($confirmedRoot in $confirmedRoots) {
            if ($screenSaver -and (Test-IsUnderPath $screenSaver $confirmedRoot)) {
                Add-Finding $findings (New-Finding -Kind 'ScreenSaver' -Name 'SCRNSAVE.EXE' -Target $desktopKey `
                    -Confidence 'Confirmed' -Reason 'Screen saver setting points under a confirmed target.' `
                    -RemovalType 'RegistryValue' -ValueName 'SCRNSAVE.EXE')
                break
            }
        }
    }

    try {
        foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            $actionExecutables = @($task.Actions | ForEach-Object { Get-NormalPath ([string]$_.Execute) } | Where-Object { $_ })
            $matchedRoot = $null
            foreach ($action in $actionExecutables) {
                foreach ($confirmedRoot in $confirmedRoots) {
                    if (Test-IsUnderPath $action $confirmedRoot) { $matchedRoot = $confirmedRoot; break }
                }
                if ($matchedRoot) { break }
            }
            $softMgrTask = $toolboxConfirmed -and $task.TaskName -like 'SoftMgrUpdate*' -and
                @($actionExecutables | Where-Object { $_ -match '(?i)\winToolBox\Tools\SoftMgr' }).Count -gt 0
            if ($matchedRoot -or $softMgrTask) {
                Add-Finding $findings (New-Finding -Kind 'ScheduledTask' -Name $task.TaskName -Target $task.TaskName `
                    -Confidence 'Confirmed' -Reason 'Task action points to a confirmed target or confirmed SoftMgr updater.' `
                    -RemovalType 'Task' -ValueName $task.TaskPath)
            }
            elseif ($task.TaskName -match '(?i)360|SoftMgr|huabao|duohuipingbao') {
                Add-Finding $findings (New-Finding -Kind 'ScheduledTask' -Name $task.TaskName -Target $task.TaskName `
                    -Confidence 'ReviewOnly' -Reason 'Task name matched, but its action was not under a confirmed target.')
            }
        }
    }
    catch {}

    foreach ($service in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue)) {
        $executable = Get-CommandExecutable ([string]$service.PathName)
        $matchedRoot = $null
        foreach ($confirmedRoot in $confirmedRoots) {
            if ($executable -and (Test-IsUnderPath $executable $confirmedRoot)) { $matchedRoot = $confirmedRoot; break }
        }
        $confirmedToolboxService = $toolboxConfirmed -and $service.Name -eq 'WinToolBoxUpdateSrv' -and
            $toolboxRoot -and $executable -and $executable.Equals((Get-NormalPath (Join-Path $toolboxRoot 'winToolBoxSrv.exe')), [StringComparison]::OrdinalIgnoreCase)
        if ($matchedRoot -or $confirmedToolboxService) {
            Add-Finding $findings (New-Finding -Kind 'Service' -Name $service.Name -Target $service.Name `
                -Confidence 'Confirmed' -Reason 'Service executable is a confirmed target or confirmed mixed-bundle updater.' `
                -RemovalType 'Service')
        }
        elseif ($service.Name -match '(?i)360|SoftMgr|huabao|duohuipingbao' -or $service.PathName -match '(?i)\360|SoftMgr|huabao|duohuipingbao') {
            Add-Finding $findings (New-Finding -Kind 'Service' -Name $service.Name -Target $service.Name `
                -Confidence 'ReviewOnly' -Reason 'Service name/path matched, but its executable was not under a confirmed target.')
        }
    }

    $driverRoot = Join-Path $env:WINDIR 'System32\drivers'
    foreach ($driver in @(Get-ChildItem -LiteralPath $driverRoot -File -Filter '360*.sys' -ErrorAction SilentlyContinue)) {
        Add-Finding $findings (New-Finding -Kind 'Driver' -Name $driver.Name -Target $driver.FullName `
            -Confidence 'ReviewOnly' -Reason 'System driver requires vendor-uninstaller and driver-package review; never auto-delete.')
    }

    $confirmedRoots = Get-ConfirmedPathRoots @($findings)
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
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
                    -Confidence 'ReviewOnly' -Reason 'Found in another Windows installation; scan-only until separately approved.' -Offline $true)
            }
        }

        $offlineUsers = Join-Path $offline 'Users'
        if (Test-Path -LiteralPath $offlineUsers) {
            foreach ($profile in @(Get-ChildItem -LiteralPath $offlineUsers -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($relative in @(
                    'AppData\Local\dhpingbao', 'AppData\Local\360Chrome', 'AppData\Local\Temp\duohuipingbao',
                    'AppData\Roaming\360se6', 'AppData\Roaming\360browser', 'AppData\Roaming\360Safe',
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
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-SafeRemovalTarget {
    param([string]$Path)

    $target = Get-NormalPath $Path
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { return $false }
    $blocked = @(
        [IO.Path]::GetPathRoot($target),
        $env:WINDIR,
        [Environment]::GetFolderPath('UserProfile'),
        [Environment]::GetEnvironmentVariable('LOCALAPPDATA'),
        [Environment]::GetEnvironmentVariable('APPDATA'),
        [Environment]::GetEnvironmentVariable('ProgramFiles'),
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'),
        [IO.Path]::GetTempPath().TrimEnd('\')
    ) | Where-Object { $_ }
    foreach ($root in $blocked) {
        $normalRoot = Get-NormalPath $root
        if ($normalRoot -and $target.Equals($normalRoot, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }

    $item = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    return $true
}

function Save-CleanupReport {
    param(
        [string]$Path,
        [string]$RunMode,
        [object[]]$Findings,
        [object[]]$Actions
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [pscustomobject]@{
        Timestamp    = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        User          = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Mode          = $RunMode
        Findings      = @($Findings)
        Actions       = @($Actions)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
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

function Remove-ConfirmedFindings {
    param([object[]]$Findings)

    $actions = New-Object System.Collections.ArrayList
    $confirmed = @($Findings | Where-Object { $_.Confidence -eq 'Confirmed' -and -not $_.Offline })
    $pathTargets = @($confirmed | Where-Object { $_.RemovalType -eq 'Path' } | ForEach-Object { $_.Target } | Sort-Object -Unique)

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'Service' })) {
        try {
            Stop-Service -Name $finding.Target -Force -ErrorAction SilentlyContinue
            $output = & sc.exe delete $finding.Target 2>&1 | Out-String
            Add-Action $actions 'DeleteService' $finding.Target 'Success' $output.Trim()
        }
        catch { Add-Action $actions 'DeleteService' $finding.Target 'Failed' $_.Exception.Message }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'Task' })) {
        try {
            Unregister-ScheduledTask -TaskName $finding.Target -TaskPath $finding.ValueName -Confirm:$false -ErrorAction Stop
            Add-Action $actions 'DeleteTask' ($finding.ValueName + $finding.Target) 'Success'
        }
        catch { Add-Action $actions 'DeleteTask' ($finding.ValueName + $finding.Target) 'Failed' $_.Exception.Message }
    }

    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $executable = Get-NormalPath ([string]$process.ExecutablePath)
        if (-not $executable) { continue }
        $shouldStop = $false
        foreach ($target in $pathTargets) {
            if (Test-IsUnderPath $executable $target) { $shouldStop = $true; break }
        }
        if ($shouldStop) {
            try {
                Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
                Add-Action $actions 'StopProcess' ("{0} ({1})" -f $process.Name, $process.ProcessId) 'Success' $executable
            }
            catch { Add-Action $actions 'StopProcess' ([string]$process.ProcessId) 'Failed' $_.Exception.Message }
        }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'RegistryValue' })) {
        try {
            Remove-ItemProperty -LiteralPath $finding.Target -Name $finding.ValueName -Force -ErrorAction Stop
            Add-Action $actions 'DeleteRegistryValue' ($finding.Target + ' :: ' + $finding.ValueName) 'Success'
        }
        catch { Add-Action $actions 'DeleteRegistryValue' ($finding.Target + ' :: ' + $finding.ValueName) 'Failed' $_.Exception.Message }
    }

    foreach ($finding in @($confirmed | Where-Object { $_.RemovalType -eq 'RegistryKey' })) {
        try {
            Remove-Item -LiteralPath $finding.Target -Recurse -Force -ErrorAction Stop
            Add-Action $actions 'DeleteRegistryKey' $finding.Target 'Success'
        }
        catch { Add-Action $actions 'DeleteRegistryKey' $finding.Target 'Failed' $_.Exception.Message }
    }

    $failedTargets = New-Object System.Collections.ArrayList
    foreach ($target in $pathTargets) {
        if (-not (Test-Path -LiteralPath $target)) { continue }
        if (-not (Test-SafeRemovalTarget $target)) {
            Add-Action $actions 'DeletePath' $target 'Skipped' 'Target validation failed or target is a reparse point.'
            continue
        }
        try {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            Add-Action $actions 'DeletePath' $target 'Success' 'Permanently removed; not sent to Recycle Bin.'
        }
        catch {
            [void]$failedTargets.Add($target)
            Add-Action $actions 'DeletePath' $target 'RetryRequired' $_.Exception.Message
        }
    }

    $explorerStopped = $false
    if ($failedTargets.Count -gt 0) {
        $holders = New-Object System.Collections.ArrayList
        foreach ($candidateProcess in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                foreach ($module in @($candidateProcess.Modules)) {
                    foreach ($target in $failedTargets) {
                        if ($module.FileName -and (Test-IsUnderPath $module.FileName $target)) {
                            if (@($holders | Where-Object { $_.Id -eq $candidateProcess.Id }).Count -eq 0) {
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
        foreach ($holder in $holders) {
            try {
                Stop-Process -Id $holder.Id -Force -ErrorAction Stop
                if ($holder.Name -eq 'explorer') { $explorerStopped = $true }
                Add-Action $actions 'StopModuleHolder' ("{0} ({1})" -f $holder.Name, $holder.Id) 'Success' $holder.Module
            }
            catch { Add-Action $actions 'StopModuleHolder' ([string]$holder.Id) 'Failed' $_.Exception.Message }
        }

        Start-Sleep -Milliseconds 700
        foreach ($target in @($failedTargets)) {
            if (-not (Test-SafeRemovalTarget $target)) { continue }
            try {
                $item = Get-Item -LiteralPath $target -Force
                if ($item.PSIsContainer) {
                    & takeown.exe /F $target /R /D Y 2>&1 | Out-Null
                    & icacls.exe $target /grant '*S-1-5-32-544:(OI)(CI)F' /T /C 2>&1 | Out-Null
                }
                else {
                    & takeown.exe /F $target 2>&1 | Out-Null
                    & icacls.exe $target /grant '*S-1-5-32-544:F' /C 2>&1 | Out-Null
                }
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                Add-Action $actions 'DeletePathRetry' $target 'Success' 'Ownership changed only on the validated target.'
            }
            catch { Add-Action $actions 'DeletePathRetry' $target 'Failed' $_.Exception.Message }
        }
    }

    if ($explorerStopped) {
        try {
            Start-Process explorer.exe
            Add-Action $actions 'RestartExplorer' 'explorer.exe' 'Started'
        }
        catch { Add-Action $actions 'RestartExplorer' 'explorer.exe' 'Failed' $_.Exception.Message }
    }

    return @($actions)
}

if ($OfflineWindowsRoot -and $Mode -eq 'Remove') {
    throw 'OfflineWindowsRoot is scan-only. Remove from an offline Windows installation requires a separate, explicit workflow.'
}

if (-not $ReportPath) {
    $reportDirectory = [Environment]::GetFolderPath('Desktop')
    if (-not $reportDirectory) { $reportDirectory = [IO.Path]::GetTempPath() }
    $ReportPath = Join-Path $reportDirectory ('360-cleanup-report-{0:yyyyMMdd-HHmmss}.json' -f (Get-Date))
}

if ($Mode -eq 'Remove') {
    if (-not $ConfirmRemoval) {
        throw 'Removal requires -ConfirmRemoval after the user has reviewed the scan.'
    }
    if (-not (Test-IsAdministrator)) {
        $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode Remove -ConfirmRemoval -ReportPath "{1}"' -f $PSCommandPath, $ReportPath
        $process = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argumentLine -Wait -PassThru
        exit $process.ExitCode
    }
}

Write-Host "Windows 360 Cleaner - $Mode" -ForegroundColor Cyan
$initialFindings = @(Get-360Findings -OfflineRoot $OfflineWindowsRoot)
Show-Findings $initialFindings

if ($Mode -eq 'Scan') {
    Save-CleanupReport -Path $ReportPath -RunMode $Mode -Findings $initialFindings -Actions @()
    Write-Host "Report: $ReportPath" -ForegroundColor Cyan
    exit 0
}

if ($Mode -eq 'Verify') {
    Save-CleanupReport -Path $ReportPath -RunMode $Mode -Findings $initialFindings -Actions @()
    $confirmedCount = @($initialFindings | Where-Object { $_.Confidence -eq 'Confirmed' }).Count
    if ($confirmedCount -gt 0) {
        Write-Warning "$confirmedCount confirmed finding(s) remain. Report: $ReportPath"
        exit 2
    }
    Write-Host "Verification passed. Report: $ReportPath" -ForegroundColor Green
    exit 0
}

$actions = @(Remove-ConfirmedFindings $initialFindings)
$remainingFindings = @(Get-360Findings)
Save-CleanupReport -Path $ReportPath -RunMode $Mode -Findings $remainingFindings -Actions $actions

Write-Host ''
Write-Host 'Removal actions:' -ForegroundColor Cyan
$actions | Format-Table Time, Action, Target, Result, Detail -AutoSize -Wrap
Write-Host ''
Write-Host 'Remaining findings:' -ForegroundColor Cyan
Show-Findings $remainingFindings
Write-Host "Report: $ReportPath" -ForegroundColor Cyan

$remainingConfirmed = @($remainingFindings | Where-Object { $_.Confidence -eq 'Confirmed' }).Count
if ($remainingConfirmed -gt 0) {
    Write-Warning "$remainingConfirmed confirmed finding(s) remain. Reboot and run Verify; do not broaden deletion without reviewing them."
    exit 2
}

Write-Host 'Confirmed targets were removed. Restart Windows once, then run Verify.' -ForegroundColor Green
exit 0

