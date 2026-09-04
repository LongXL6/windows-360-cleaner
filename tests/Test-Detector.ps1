#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CleanerScriptPath = (Join-Path $PSScriptRoot '..\scripts\Invoke-360Cleanup.ps1')
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$detectorTestPath = $PSCommandPath
$helpersPath = Join-Path $PSScriptRoot 'Test-Helpers.ps1'
. $helpersPath

$run = New-TestRun -Name 'Detector tests'
$fixtureRoot = $null
$originalKnownFolders = $null
$libraryLoaded = $false
$previousTestMode = [Environment]::GetEnvironmentVariable('WINDOWS_360_CLEANER_TEST_MODE', 'Process')

try {
    $env:WINDOWS_360_CLEANER_TEST_MODE = 'ISOLATED-SAFETY-TEST'
    try {
        . $CleanerScriptPath -InternalTestLibraryOnly
        $libraryLoaded = $true
    }
    finally {
        if ($null -eq $previousTestMode) {
            Remove-Item Env:\WINDOWS_360_CLEANER_TEST_MODE -ErrorAction SilentlyContinue
        }
        else {
            $env:WINDOWS_360_CLEANER_TEST_MODE = $previousTestMode
        }
    }

    $originalKnownFolders = $script:KnownFolders
    $fixtureRoot = New-TestDirectory
    $script:KnownFolders = [ordered]@{
        LocalAppData    = Join-Path $fixtureRoot 'LocalAppData'
        RoamingAppData  = Join-Path $fixtureRoot 'RoamingAppData'
        ProgramFiles    = Join-Path $fixtureRoot 'ProgramFiles'
        ProgramFilesX86 = Join-Path $fixtureRoot 'ProgramFilesX86'
        ProgramData     = Join-Path $fixtureRoot 'ProgramData'
        UserProfile     = Join-Path $fixtureRoot 'UserProfile'
        Desktop         = Join-Path $fixtureRoot 'Desktop'
        Temp            = Join-Path $fixtureRoot 'Temp'
        Windows         = Join-Path $fixtureRoot 'Windows'
    }
    foreach ($path in $script:KnownFolders.Values) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    Invoke-TestCase -Run $run -Name 'test files use the PowerShell 5.1 source contract' -Test {
        Assert-TestPowerShellFileContract -Path $helpersPath
        Assert-TestPowerShellFileContract -Path $detectorTestPath
    }

    Invoke-TestCase -Run $run -Name 'finding construction and de-duplication stay deterministic' -Test {
        $finding = New-Finding -Kind 'Startup' -Name 'Fixture startup' `
            -Target 'HKCU:\Software\Fixture\Run' -Confidence 'ReviewOnly' `
            -Reason 'Isolated fixture' -ValueName 'FixtureValue'
        Assert-TestSequenceEqual `
            -Expected @(
                'Kind', 'Name', 'Target', 'Confidence', 'Reason', 'RemovalType',
                'ValueName', 'IdentityFingerprint', 'Offline'
            ) `
            -Actual @($finding.PSObject.Properties.Name) `
            -Message 'Finding schema changed unexpectedly.'
        Assert-TestEqual -Expected 'None' -Actual $finding.RemovalType `
            -Message 'Review-only findings must default to a non-removing action.'
        Assert-TestEqual -Expected '' -Actual $finding.IdentityFingerprint `
            -Message 'Findings without a captured exact identity must default to an empty fingerprint.'
        Assert-TestFalse -Condition $finding.Offline -Message 'Live findings must not be marked offline by default.'

        $items = New-Object System.Collections.ArrayList
        Add-Finding -List $items -Finding $finding
        Add-Finding -List $items -Finding $finding
        Assert-TestEqual -Expected 1 -Actual $items.Count `
            -Message 'An identical detector result was added more than once.'

        $separateValue = New-Finding -Kind 'Startup' -Name 'Fixture startup 2' `
            -Target 'HKCU:\Software\Fixture\Run' -Confidence 'ReviewOnly' `
            -Reason 'Isolated fixture' -ValueName 'OtherValue'
        Add-Finding -List $items -Finding $separateValue
        Assert-TestEqual -Expected 2 -Actual $items.Count `
            -Message 'Distinct registry value findings were incorrectly de-duplicated.'
    }

    Invoke-TestCase -Run $run -Name 'command executable parsing is deterministic' -Test {
        $quoted = Get-CommandExecutable '"C:\Program Files\Fixture\fixture.exe" --quiet'
        $bare = Get-CommandExecutable 'C:\Fixture\fixture.exe --quiet'
        Assert-TestEqual -Expected 'C:\Program Files\Fixture\fixture.exe' -Actual $quoted `
            -Message 'Quoted executable parsing changed.'
        Assert-TestEqual -Expected 'C:\Fixture\fixture.exe' -Actual $bare `
            -Message 'Bare executable parsing changed.'
        Assert-TestNull -Actual (Get-CommandExecutable 'not-an-executable --quiet') `
            -Message 'A command without an executable extension should not produce a path.'
    }

    Invoke-TestCase -Run $run -Name 'browser applications and user data have separate evidence gates' -Test {
        $browserLayouts = @(
            [pscustomobject]@{
                Name        = '360se6'
                Application = Join-Path $script:KnownFolders.RoamingAppData '360se6\Application'
                UserData    = Join-Path $script:KnownFolders.RoamingAppData '360se6\User Data'
                Root        = Join-Path $script:KnownFolders.RoamingAppData '360se6'
                Container   = Join-Path $script:KnownFolders.RoamingAppData '360se6'
                MarkerName  = '360se.exe'
            },
            [pscustomobject]@{
                Name        = '360Chrome'
                Application = Join-Path $script:KnownFolders.LocalAppData '360Chrome\Chrome\Application'
                UserData    = Join-Path $script:KnownFolders.LocalAppData '360Chrome\Chrome\User Data'
                Root        = Join-Path $script:KnownFolders.LocalAppData '360Chrome'
                Container   = Join-Path $script:KnownFolders.LocalAppData '360Chrome\Chrome'
                MarkerName  = '360chrome.exe'
            },
            [pscustomobject]@{
                Name        = '360ChromeX'
                Application = Join-Path $script:KnownFolders.LocalAppData '360ChromeX\Chrome\Application'
                UserData    = Join-Path $script:KnownFolders.LocalAppData '360ChromeX\Chrome\User Data'
                Root        = Join-Path $script:KnownFolders.LocalAppData '360ChromeX'
                Container   = Join-Path $script:KnownFolders.LocalAppData '360ChromeX\Chrome'
                MarkerName  = '360chromex.exe'
            }
        )
        $evidencePaths = @()
        foreach ($layout in $browserLayouts) {
            New-Item -ItemType Directory -Path $layout.Application -Force | Out-Null
            New-Item -ItemType Directory -Path $layout.UserData -Force | Out-Null
            $marker = Join-Path $layout.Application $layout.MarkerName
            Set-Content -LiteralPath $marker -Value 'ISOLATED-BROWSER-MARKER'
            $evidencePaths += $marker
        }
        $legacyProfile = Join-Path $script:KnownFolders.RoamingAppData '360browser'
        New-Item -ItemType Directory -Path $legacyProfile -Force | Out-Null

        $noEvidenceFake = New-Fake360CleanupRuntimeProvider
        Set-360CleanupRuntimeProvider -Provider $noEvidenceFake.Provider -Context $noEvidenceFake.Context
        try {
            $noEvidenceFindings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        foreach ($layout in $browserLayouts) {
            $applicationFinding = @($noEvidenceFindings | Where-Object {
                $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $layout.Application)
            })
            Assert-TestEqual -Expected 1 -Actual $applicationFinding.Count `
                -Message ("The {0} Application fixture was not surfaced exactly once." -f $layout.Name)
            Assert-TestEqual -Expected 'ReviewOnly' -Actual $applicationFinding[0].Confidence `
                -Message ("The {0} Application path was confirmed without product evidence." -f $layout.Name)
            Assert-TestEqual -Expected 'None' -Actual $applicationFinding[0].RemovalType `
                -Message ("The {0} Application path became removable without product evidence." -f $layout.Name)
        }

        $evidenceFake = New-Fake360CleanupRuntimeProvider -ProductEvidencePaths $evidencePaths
        Set-360CleanupRuntimeProvider -Provider $evidenceFake.Provider -Context $evidenceFake.Context
        try {
            $defaultFindings = @(Get-360Findings)
            $optInFindings = @(Get-360Findings -IncludeProfiles:$true)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        foreach ($layout in $browserLayouts) {
            $applicationFinding = @($defaultFindings | Where-Object {
                $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $layout.Application)
            })
            Assert-TestEqual -Expected 1 -Actual $applicationFinding.Count `
                -Message ("The evidenced {0} Application fixture was not surfaced exactly once." -f $layout.Name)
            Assert-TestEqual -Expected 'Confirmed' -Actual $applicationFinding[0].Confidence `
                -Message ("The evidenced {0} Application path was not confirmed." -f $layout.Name)
            Assert-TestEqual -Expected 'Path' -Actual $applicationFinding[0].RemovalType `
                -Message ("The evidenced {0} Application path was not independently removable." -f $layout.Name)

            $defaultUserData = @($defaultFindings | Where-Object {
                $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $layout.UserData)
            })
            Assert-TestEqual -Expected 1 -Actual $defaultUserData.Count `
                -Message ("The {0} User Data fixture was not surfaced exactly once." -f $layout.Name)
            Assert-TestEqual -Expected 'ReviewOnly' -Actual $defaultUserData[0].Confidence `
                -Message ("The {0} User Data path was confirmed without profile opt-in." -f $layout.Name)
            Assert-TestEqual -Expected 'None' -Actual $defaultUserData[0].RemovalType `
                -Message ("The {0} User Data path became removable without profile opt-in." -f $layout.Name)

            $optInUserData = @($optInFindings | Where-Object {
                $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $layout.UserData)
            })
            Assert-TestEqual -Expected 1 -Actual $optInUserData.Count `
                -Message ("The opted-in {0} User Data fixture was not surfaced exactly once." -f $layout.Name)
            Assert-TestEqual -Expected 'Confirmed' -Actual $optInUserData[0].Confidence `
                -Message ("The opted-in {0} User Data path was not confirmed." -f $layout.Name)
            Assert-TestEqual -Expected 'Path' -Actual $optInUserData[0].RemovalType `
                -Message ("The opted-in {0} User Data path was not independently removable." -f $layout.Name)

            Assert-TestTrue -Condition (Test-IsExpectedRemovalPath $layout.Application) `
                -Message ("The exact {0} Application path is missing from the removal allowlist." -f $layout.Name)
            Assert-TestTrue -Condition (Test-IsExpectedRemovalPath $layout.UserData) `
                -Message ("The exact {0} User Data path is missing from the opt-in removal allowlist." -f $layout.Name)
            Assert-TestFalse -Condition (Test-IsExpectedRemovalPath $layout.Root) `
                -Message ("The whole {0} browser root must never be an automatic removal target." -f $layout.Name)
            Assert-TestFalse -Condition (Test-IsExpectedRemovalPath $layout.Container) `
                -Message ("The {0} browser container must never be an automatic removal target." -f $layout.Name)

            $wholeRootFinding = @($defaultFindings | Where-Object {
                $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $layout.Root)
            })
            Assert-TestEqual -Expected 0 -Actual $wholeRootFinding.Count `
                -Message ("The whole {0} browser root was emitted as a path finding." -f $layout.Name)
        }

        $defaultLegacyProfile = @($defaultFindings | Where-Object {
            $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $legacyProfile)
        })
        Assert-TestEqual -Expected 1 -Actual $defaultLegacyProfile.Count `
            -Message 'The legacy 360browser profile was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $defaultLegacyProfile[0].Confidence `
            -Message 'The legacy 360browser profile was confirmed without profile opt-in.'
        Assert-TestEqual -Expected 'None' -Actual $defaultLegacyProfile[0].RemovalType `
            -Message 'The legacy 360browser profile became removable without profile opt-in.'

        $optInLegacyProfile = @($optInFindings | Where-Object {
            $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $legacyProfile)
        })
        Assert-TestEqual -Expected 1 -Actual $optInLegacyProfile.Count `
            -Message 'The opted-in legacy 360browser profile was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $optInLegacyProfile[0].Confidence `
            -Message 'The opted-in legacy 360browser profile was not confirmed.'
        Assert-TestEqual -Expected 'Path' -Actual $optInLegacyProfile[0].RemovalType `
            -Message 'The opted-in legacy 360browser profile was not removable.'
        Assert-TestTrue -Condition (Test-IsExpectedRemovalPath $legacyProfile) `
            -Message 'The exact legacy 360browser profile is missing from the opt-in removal allowlist.'
        Assert-TestFalse -Condition (Test-IsExpectedRemovalPath $script:KnownFolders.RoamingAppData) `
            -Message 'The whole Roaming AppData parent must never enter the removal allowlist.'
    }

    Invoke-TestCase -Run $run -Name 'secoresdk browser product requires local product evidence' -Test {
        $secoreProduct = Join-Path $script:KnownFolders.RoamingAppData 'secoresdk\360se6'
        $secoreParent = Join-Path $script:KnownFolders.RoamingAppData 'secoresdk'
        New-Item -ItemType Directory -Path $secoreProduct -Force | Out-Null
        $marker = Join-Path $secoreProduct 'secore.dll'
        Set-Content -LiteralPath $marker -Value 'ISOLATED-SECORE-MARKER'

        $noEvidenceFake = New-Fake360CleanupRuntimeProvider
        Set-360CleanupRuntimeProvider -Provider $noEvidenceFake.Provider -Context $noEvidenceFake.Context
        try {
            $noEvidenceFindings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        $unconfirmed = @($noEvidenceFindings | Where-Object {
            $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $secoreProduct)
        })
        Assert-TestEqual -Expected 1 -Actual $unconfirmed.Count `
            -Message 'The secoresdk\\360se6 product fixture was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $unconfirmed[0].Confidence `
            -Message 'The secoresdk\\360se6 product was confirmed without product evidence.'
        Assert-TestEqual -Expected 'None' -Actual $unconfirmed[0].RemovalType `
            -Message 'The secoresdk\\360se6 product became removable without product evidence.'

        $evidenceFake = New-Fake360CleanupRuntimeProvider -ProductEvidencePaths @($marker)
        Set-360CleanupRuntimeProvider -Provider $evidenceFake.Provider -Context $evidenceFake.Context
        try {
            $evidencedFindings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        $confirmed = @($evidencedFindings | Where-Object {
            $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $secoreProduct)
        })
        Assert-TestEqual -Expected 1 -Actual $confirmed.Count `
            -Message 'The evidenced secoresdk\\360se6 product was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $confirmed[0].Confidence `
            -Message 'The evidenced secoresdk\\360se6 product was not confirmed.'
        Assert-TestEqual -Expected 'Path' -Actual $confirmed[0].RemovalType `
            -Message 'The evidenced secoresdk\\360se6 product was not independently removable.'
        Assert-TestTrue -Condition (Test-IsExpectedRemovalPath $secoreProduct) `
            -Message 'The exact secoresdk\\360se6 product is missing from the removal allowlist.'
        Assert-TestFalse -Condition (Test-IsExpectedRemovalPath $secoreParent) `
            -Message 'The whole secoresdk parent must never be an automatic removal target.'
    }

    Invoke-TestCase -Run $run -Name 'Run fallbacks separate name and executable-path evidence' -Test {
        $runRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $runOnceRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
        $fake = New-Fake360CleanupRuntimeProvider -RegistryValues @{
            $runRoot = [pscustomobject]@{
                sesvc = 'C:\Fixture\ordinary-service.exe --background'
            }
            $runOnceRoot = [pscustomobject]@{
                FixtureBrowserHelper = 'C:\Fixture\sesvc.exe --background'
                FixtureUpdater = 'C:\Fixture\ordinary-updater.exe --background'
            }
        }

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $sesvcFinding = @($findings | Where-Object {
            $_.Kind -eq 'Startup' -and $_.Target -eq $runRoot -and $_.ValueName -eq 'sesvc'
        })
        Assert-TestEqual -Expected 1 -Actual $sesvcFinding.Count `
            -Message 'The sesvc Run fallback was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $sesvcFinding[0].Confidence `
            -Message 'A sesvc name-only fallback without confirmed Application evidence was auto-confirmed.'
        Assert-TestEqual -Expected 'None' -Actual $sesvcFinding[0].RemovalType `
            -Message 'A sesvc name-only fallback without confirmed Application evidence became removable.'

        $pathOnlyFinding = @($findings | Where-Object {
            $_.Kind -eq 'Startup' -and $_.Target -eq $runOnceRoot -and $_.ValueName -eq 'FixtureBrowserHelper'
        })
        Assert-TestEqual -Expected 1 -Actual $pathOnlyFinding.Count `
            -Message 'The sesvc executable-path-only RunOnce fallback was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $pathOnlyFinding[0].Confidence `
            -Message 'A sesvc executable-path-only fallback was auto-confirmed.'
        Assert-TestEqual -Expected 'None' -Actual $pathOnlyFinding[0].RemovalType `
            -Message 'A sesvc executable-path-only fallback became removable.'

        $ordinaryFinding = @($findings | Where-Object {
            $_.Kind -eq 'Startup' -and $_.Target -eq $runOnceRoot -and $_.ValueName -eq 'FixtureUpdater'
        })
        Assert-TestEqual -Expected 0 -Actual $ordinaryFinding.Count `
            -Message 'An unrelated RunOnce value was surfaced by the sesvc fallback.'
    }

    Invoke-TestCase -Run $run -Name '360ChromeX uninstall names use an explicit product boundary' -Test {
        $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $chromeXKey = $uninstallRoot + '\360ChromeX'
        $unrelatedKey = $uninstallRoot + '\360ChromeXylophone'
        $fake = New-Fake360CleanupRuntimeProvider `
            -RegistrySubKeys @{
                $uninstallRoot = @(
                    [pscustomobject]@{ PSPath = $chromeXKey },
                    [pscustomobject]@{ PSPath = $unrelatedKey }
                )
            } `
            -RegistryValues @{
                $chromeXKey = [pscustomobject]@{
                    DisplayName = '360ChromeX 15.0'
                    Publisher = ''
                    InstallLocation = ''
                    UninstallString = ''
                }
                $unrelatedKey = [pscustomobject]@{
                    DisplayName = '360ChromeXylophone'
                    Publisher = 'Unrelated Fixture Publisher'
                    InstallLocation = ''
                    UninstallString = ''
                }
            }

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $chromeXFinding = @($findings | Where-Object {
            $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $chromeXKey
        })
        Assert-TestEqual -Expected 1 -Actual $chromeXFinding.Count `
            -Message 'The explicit 360ChromeX uninstall product was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $chromeXFinding[0].Confidence `
            -Message 'An empty 360ChromeX uninstall record was incorrectly treated as proven orphan evidence.'
        Assert-TestEqual -Expected 'None' -Actual $chromeXFinding[0].RemovalType `
            -Message 'An empty 360ChromeX uninstall record became removable.'

        $unrelatedFinding = @($findings | Where-Object {
            $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $unrelatedKey
        })
        Assert-TestEqual -Expected 0 -Actual $unrelatedFinding.Count `
            -Message 'A neighboring non-product name crossed the 360ChromeX product boundary.'
    }

    Invoke-TestCase -Run $run -Name 'uninstall records require positive stale evidence before registry removal' -Test {
        $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $liveUninstaller = Join-Path $fixtureRoot 'Vendor\uninstall.exe'
        $liveLocation = Join-Path $fixtureRoot 'LiveProduct'
        New-Item -ItemType Directory -Path (Split-Path -Parent $liveUninstaller) -Force | Out-Null
        New-Item -ItemType Directory -Path $liveLocation -Force | Out-Null
        Set-Content -LiteralPath $liveUninstaller -Value 'ISOLATED-UNINSTALLER'

        $liveUninstallerKey = $uninstallRoot + '\LiveUninstaller'
        $orphanedKey = $uninstallRoot + '\Orphaned'
        $unknownKey = $uninstallRoot + '\Unknown'
        $bareCommandKey = $uninstallRoot + '\BareCommand'
        $liveLocationKey = $uninstallRoot + '\LiveLocation'
        $liveIconKey = $uninstallRoot + '\LiveIcon'
        $missingOnlyKey = $uninstallRoot + '\MissingOnly'
        $liveQuietKey = $uninstallRoot + '\LiveQuietUninstaller'
        $unreadableIdentityKey = $uninstallRoot + '\UnreadableIdentity'
        $unreadableIdentityChild = $unreadableIdentityKey + '\Child'
        $missingLocation = Join-Path $fixtureRoot 'MissingProduct'
        $missingUninstaller = Join-Path $fixtureRoot 'Missing\uninstall.exe'
        $registryValues = @{
            $liveUninstallerKey = [pscustomobject]@{
                DisplayName = '360 Total Security Live Uninstaller'
                InstallLocation = ''
                UninstallString = ('"{0}" /S' -f $liveUninstaller)
            }
            $orphanedKey = [pscustomobject]@{
                DisplayName = '360 Total Security Orphaned'
                InstallLocation = $missingLocation
                UninstallString = ('"{0}" /S' -f $missingUninstaller)
            }
            $unknownKey = [pscustomobject]@{
                DisplayName = '360 Total Security Unknown'
                InstallLocation = ''
                UninstallString = ''
            }
            $bareCommandKey = [pscustomobject]@{
                DisplayName = '360 Total Security MSI'
                InstallLocation = ''
                UninstallString = 'MsiExec.exe /X{00000000-0000-0000-0000-000000000360}'
            }
            $liveLocationKey = [pscustomobject]@{
                DisplayName = '360 Total Security Live Location'
                InstallLocation = $liveLocation
                UninstallString = ('"{0}" /S' -f $missingUninstaller)
            }
            $liveIconKey = [pscustomobject]@{
                DisplayName = '360 Total Security Live Icon'
                InstallLocation = $missingLocation
                UninstallString = ('"{0}" /S' -f $missingUninstaller)
                DisplayIcon = ('"{0}",0' -f $liveUninstaller)
            }
            $missingOnlyKey = [pscustomobject]@{
                DisplayName = '360 Total Security Missing Uninstaller'
                InstallLocation = ''
                UninstallString = ('"{0}" /S' -f $missingUninstaller)
            }
            $liveQuietKey = [pscustomobject]@{
                DisplayName = '360 Total Security Live Quiet Uninstaller'
                InstallLocation = $missingLocation
                UninstallString = ('"{0}" /S' -f $missingUninstaller)
                QuietUninstallString = ('"{0}" /quiet' -f $liveUninstaller)
            }
            $unreadableIdentityKey = [pscustomobject]@{
                DisplayName = '360 Total Security Unreadable Identity'
                InstallLocation = $missingLocation
                UninstallString = ('"{0}" /S' -f $missingUninstaller)
            }
        }
        $subKeys = @($registryValues.Keys | Sort-Object | ForEach-Object {
            [pscustomobject]@{ PSPath = $_ }
        })
        $registrySubKeys = @{
            $uninstallRoot = $subKeys
            $unreadableIdentityKey = @([pscustomobject]@{
                PSPath = $unreadableIdentityChild; PSChildName = 'Child'
            })
        }
        $fake = New-Fake360CleanupRuntimeProvider `
            -RegistrySubKeys $registrySubKeys `
            -RegistryValues $registryValues

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        foreach ($reviewOnlyKey in @(
            $liveUninstallerKey, $unknownKey, $bareCommandKey, $liveLocationKey, $liveIconKey, $liveQuietKey
        )) {
            $finding = @($findings | Where-Object { $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $reviewOnlyKey })
            Assert-TestEqual -Expected 1 -Actual $finding.Count `
                -Message "The review-only uninstall fixture was not surfaced exactly once: $reviewOnlyKey"
            Assert-TestEqual -Expected 'ReviewOnly' -Actual $finding[0].Confidence `
                -Message "An uninstall record without proven orphan evidence was confirmed: $reviewOnlyKey"
            Assert-TestEqual -Expected 'None' -Actual $finding[0].RemovalType `
                -Message "An uninstall record without proven orphan evidence became removable: $reviewOnlyKey"
        }

        $liveFinding = @($findings | Where-Object { $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $liveUninstallerKey })
        Assert-TestTrue -Condition ($liveFinding[0].Reason -match 'live vendor uninstaller') `
            -Message 'The available vendor uninstaller was not explained in the finding.'

        foreach ($confirmedKey in @($orphanedKey, $missingOnlyKey)) {
            $orphanedFinding = @($findings | Where-Object {
                $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $confirmedKey
            })
            Assert-TestEqual -Expected 1 -Actual $orphanedFinding.Count `
                -Message "The genuinely orphaned uninstall fixture was not surfaced exactly once: $confirmedKey"
            Assert-TestEqual -Expected 'Confirmed' -Actual $orphanedFinding[0].Confidence `
                -Message "A record whose explicit file references are stale was not confirmed: $confirmedKey"
            Assert-TestEqual -Expected 'RegistryKey' -Actual $orphanedFinding[0].RemovalType `
                -Message "A proven orphan uninstall record did not retain exact-key removal: $confirmedKey"
            Assert-TestTrue -Condition ([string]$orphanedFinding[0].IdentityFingerprint -cmatch '^[0-9A-F]{64}$') `
                -Message "A confirmed registry-key finding did not capture an uppercase identity fingerprint: $confirmedKey"
            $rootSnapshotCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues' | Where-Object {
                $_.Arguments[0] -eq $confirmedKey
            })
            Assert-TestEqual -Expected 1 -Actual $rootSnapshotCalls.Count `
                -Message "Registry-key attribution and root fingerprinting did not share one snapshot: $confirmedKey"
        }

        $unreadableIdentityFinding = @($findings | Where-Object {
            $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $unreadableIdentityKey
        })
        Assert-TestEqual -Expected 1 -Actual $unreadableIdentityFinding.Count `
            -Message 'The unreadable identity fixture was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $unreadableIdentityFinding[0].Confidence `
            -Message 'An unreadable registry-key identity remained confirmed.'
        Assert-TestEqual -Expected 'None' -Actual $unreadableIdentityFinding[0].RemovalType `
            -Message 'An unreadable registry-key identity remained removable.'
        Assert-TestEqual -Expected '' -Actual $unreadableIdentityFinding[0].IdentityFingerprint `
            -Message 'An unreadable registry-key identity retained an approval fingerprint.'
        Assert-TestTrue -Condition ([string]$unreadableIdentityFinding[0].Reason -match '(?i)identity fingerprint') `
            -Message 'The identity-read failure was not explained in the review-only finding.'
    }

    Invoke-TestCase -Run $run -Name 'exact Duohui root emits one metadata-bound hashed vendor uninstaller' -Test {
        $installRoot = Join-Path $script:KnownFolders.LocalAppData 'dhpingbao'
        $vendorPath = Join-Path $installRoot 'huabaosetup.exe'
        $tempVendor = Join-Path $script:KnownFolders.Temp 'duohuipingbao\huabaosetup.exe'
        $outsideVendor = Join-Path $script:KnownFolders.LocalAppData 'OtherProduct\huabaosetup.exe'
        foreach ($path in @($vendorPath, $tempVendor, $outsideVendor)) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            Set-Content -LiteralPath $path -Value ('ISOLATED-DUOHUI-' + (Split-Path -Parent $path))
        }
        $expectedHash = (Get-FileHash -LiteralPath $vendorPath -Algorithm SHA256).Hash
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($vendorPath, $tempVendor, $outsideVendor) `
            -TrustedDuohuiVendorPaths @($vendorPath)

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $rootFinding = @($findings | Where-Object {
            $_.Kind -eq 'Path' -and $_.Target -eq (Get-NormalPath $installRoot)
        })
        Assert-TestEqual -Expected 1 -Actual $rootFinding.Count `
            -Message 'The exact dhpingbao root was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $rootFinding[0].Confidence `
            -Message 'The exact dhpingbao root with Duohui metadata was not confirmed.'

        $vendorFinding = @($findings | Where-Object { $_.Kind -eq 'VendorUninstaller' })
        Assert-TestEqual -Expected 1 -Actual $vendorFinding.Count `
            -Message 'The detector emitted a missing or extra vendor-uninstaller finding.'
        Assert-TestEqual -Expected 'Duohui vendor uninstaller' -Actual $vendorFinding[0].Name `
            -Message 'The vendor-uninstaller finding name changed unexpectedly.'
        Assert-TestEqual -Expected (Get-NormalPath $vendorPath) -Actual $vendorFinding[0].Target `
            -Message 'A Temp or root-outside huabaosetup.exe became the vendor target.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $vendorFinding[0].Confidence `
            -Message 'The exact metadata-backed vendor uninstaller was not confirmed.'
        Assert-TestEqual -Expected 'VendorUninstaller' -Actual $vendorFinding[0].RemovalType `
            -Message 'The exact vendor uninstaller did not retain its dedicated removal type.'
        Assert-TestEqual -Expected $expectedHash -Actual $vendorFinding[0].ValueName `
            -Message 'The vendor finding did not bind approval to the scanned SHA-256.'
        Assert-TestTrue -Condition ($vendorFinding[0].ValueName -cmatch '^[0-9A-F]{64}$') `
            -Message 'The vendor SHA-256 must be 64 uppercase hexadecimal characters.'
        Assert-TestTrue -Condition ([string]$vendorFinding[0].Reason).Contains($expectedHash) `
            -Message 'The vendor finding reason did not expose the complete scanned SHA-256.'
    }

    Invoke-TestCase -Run $run -Name 'metadata without the exact trusted signer stays review only' -Test {
        $installRoot = Join-Path $script:KnownFolders.LocalAppData 'dhpingbao'
        $vendorPath = Join-Path $installRoot 'huabaosetup.exe'
        $fake = New-Fake360CleanupRuntimeProvider -UseRealPathReads `
            -ProductEvidencePaths @($vendorPath)

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $vendorFinding = @($findings | Where-Object {
            $_.Kind -eq 'VendorUninstaller' -and $_.Target -eq (Get-NormalPath $vendorPath)
        })
        Assert-TestEqual -Expected 1 -Actual $vendorFinding.Count `
            -Message 'The exact untrusted vendor candidate disappeared from review output.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $vendorFinding[0].Confidence `
            -Message 'Forgeable product metadata promoted an untrusted LocalAppData executable.'
        Assert-TestEqual -Expected 'None' -Actual $vendorFinding[0].RemovalType `
            -Message 'An untrusted LocalAppData executable became runnable.'
        Assert-TestEqual -Expected '' -Actual $vendorFinding[0].ValueName `
            -Message 'An untrusted LocalAppData executable was hashed into an approval identity.'
    }

    Invoke-TestCase -Run $run -Name 'Duohui uninstall records require exact key display name and publisher' -Test {
        $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $installRoot = Join-Path $script:KnownFolders.LocalAppData 'dhpingbao'
        $vendorPath = Join-Path $installRoot 'huabaosetup.exe'
        $scenarios = @(
            [pscustomobject]@{ Leaf = 'duohuipingbao'; DisplayName = 'DUOHUIPINGBAO'; Publisher = 'DuohuiPingbao'; Expected = 1 },
            [pscustomobject]@{ Leaf = 'duohuipingbao-helper'; DisplayName = 'duohuipingbao'; Publisher = 'duohuipingbao'; Expected = 0 },
            [pscustomobject]@{ Leaf = 'duohuipingbao'; DisplayName = 'duohuipingbao helper'; Publisher = 'duohuipingbao'; Expected = 0 },
            [pscustomobject]@{ Leaf = 'duohuipingbao'; DisplayName = 'duohuipingbao'; Publisher = 'duohuipingbao helper'; Expected = 0 }
        )

        foreach ($scenario in $scenarios) {
            $keyPath = $uninstallRoot + '\' + $scenario.Leaf
            $fake = New-Fake360CleanupRuntimeProvider `
                -RegistrySubKeys @{
                    $uninstallRoot = @([pscustomobject]@{ PSPath = $keyPath; PSChildName = $scenario.Leaf })
                } `
                -RegistryValues @{
                    $keyPath = [pscustomobject]@{
                        DisplayName = $scenario.DisplayName
                        Publisher = $scenario.Publisher
                        InstallLocation = $installRoot
                        UninstallString = ('"{0}" /registry-supplied-argument' -f $vendorPath)
                    }
                } `
                -ProductEvidencePaths @($vendorPath)

            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $findings = @(Get-360Findings)
            }
            finally {
                Reset-360CleanupRuntimeProvider
            }

            $installedProduct = @($findings | Where-Object {
                $_.Kind -eq 'InstalledProduct' -and $_.Target -eq $keyPath
            })
            Assert-TestEqual -Expected $scenario.Expected -Actual $installedProduct.Count `
                -Message ('The exact Duohui uninstall identity boundary failed for: ' + $keyPath)
            if ($scenario.Expected -eq 1) {
                Assert-TestEqual -Expected 'ReviewOnly' -Actual $installedProduct[0].Confidence `
                    -Message 'A live exact Duohui uninstall record must not be removed as an orphan.'
                Assert-TestEqual -Expected 'None' -Actual $installedProduct[0].RemovalType `
                    -Message 'A live exact Duohui uninstall record became directly removable.'
            }
        }
    }

    Invoke-TestCase -Run $run -Name 'Duohui HKCU residues are removable only with a proven orphan record' -Test {
        $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $uninstallKey = $uninstallRoot + '\duohuipingbao'
        $softwareRoot = 'HKCU:\Software'
        $directResidue = $softwareRoot + '\duohuipingbao'
        $guidParent = $softwareRoot + '\{01234567-89AB-CDEF-0123-456789ABCDEF}'
        $guidResidue = $guidParent + '\duohuipingbao'
        $nearParent = $softwareRoot + '\{01234567-89AB-CDEF-0123-NOT-A-GUID}'
        $nearResidue = $nearParent + '\duohuipingbao'
        $softwareSubKeys = @(
            [pscustomobject]@{ PSPath = $guidParent; PSChildName = '{01234567-89AB-CDEF-0123-456789ABCDEF}' },
            [pscustomobject]@{ PSPath = $nearParent; PSChildName = '{01234567-89AB-CDEF-0123-NOT-A-GUID}' }
        )
        $residuePaths = @($directResidue, $guidResidue, $nearResidue)
        $missingRoot = Join-Path $fixtureRoot 'MissingDuohui'
        $missingVendor = Join-Path $missingRoot 'huabaosetup.exe'

        $recordStates = @(
            [pscustomobject]@{
                Name = 'Orphan'; IncludeRecord = $true; ExpectedConfidence = 'Confirmed'; ExpectedRemoval = 'RegistryKey'
                InstallLocation = $missingRoot; UninstallString = ('"{0}" /uninstall:byUserName' -f $missingVendor)
            },
            [pscustomobject]@{
                Name = 'Live'; IncludeRecord = $true; ExpectedConfidence = 'ReviewOnly'; ExpectedRemoval = 'None'
                InstallLocation = (Join-Path $script:KnownFolders.LocalAppData 'dhpingbao')
                UninstallString = ('"{0}" /uninstall:byUserName' -f (Join-Path $script:KnownFolders.LocalAppData 'dhpingbao\huabaosetup.exe'))
            },
            [pscustomobject]@{
                Name = 'NoRecord'; IncludeRecord = $false; ExpectedConfidence = 'ReviewOnly'; ExpectedRemoval = 'None'
                InstallLocation = ''; UninstallString = ''
            }
        )

        foreach ($recordState in $recordStates) {
            $registrySubKeys = @{ $softwareRoot = $softwareSubKeys }
            $registryValues = @{}
            $registryValues[$directResidue] = [pscustomobject]@{}
            $registryValues[$guidResidue] = [pscustomobject]@{}
            if ($recordState.IncludeRecord) {
                $registrySubKeys[$uninstallRoot] = @(
                    [pscustomobject]@{ PSPath = $uninstallKey; PSChildName = 'duohuipingbao' }
                )
                $registryValues[$uninstallKey] = [pscustomobject]@{
                    DisplayName = 'duohuipingbao'
                    Publisher = 'duohuipingbao'
                    InstallLocation = $recordState.InstallLocation
                    UninstallString = $recordState.UninstallString
                }
            }
            $fake = New-Fake360CleanupRuntimeProvider -ExistingRegistryPaths $residuePaths `
                -RegistrySubKeys $registrySubKeys -RegistryValues $registryValues `
                -ProductEvidencePaths @((Join-Path $script:KnownFolders.LocalAppData 'dhpingbao\huabaosetup.exe'))

            Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
            try {
                $findings = @(Get-360Findings)
            }
            finally {
                Reset-360CleanupRuntimeProvider
            }

            $residueFindings = @($findings | Where-Object { $_.Kind -eq 'RegistryResidue' } | Sort-Object Target)
            Assert-TestEqual -Expected 2 -Actual $residueFindings.Count `
                -Message ("The {0} scan emitted a missing residue or accepted a non-GUID parent." -f $recordState.Name)
            Assert-TestSequenceEqual -Expected @(@($directResidue, $guidResidue) | Sort-Object) `
                -Actual @($residueFindings.Target) `
                -Message ("The {0} scan returned the wrong exact HKCU residues." -f $recordState.Name)
            foreach ($residueFinding in $residueFindings) {
                Assert-TestEqual -Expected $recordState.ExpectedConfidence -Actual $residueFinding.Confidence `
                    -Message ("The {0} residue confidence did not respect the orphan gate." -f $recordState.Name)
                Assert-TestEqual -Expected $recordState.ExpectedRemoval -Actual $residueFinding.RemovalType `
                    -Message ("The {0} residue removal type did not respect the orphan gate." -f $recordState.Name)
                if ($recordState.ExpectedRemoval -eq 'RegistryKey') {
                    Assert-TestTrue `
                        -Condition ([string]$residueFinding.IdentityFingerprint -cmatch '^[0-9A-F]{64}$') `
                        -Message 'A confirmed Duohui registry residue lacked its exact identity fingerprint.'
                }
                else {
                    Assert-TestEqual -Expected '' -Actual $residueFinding.IdentityFingerprint `
                        -Message 'A review-only Duohui registry residue retained a removal fingerprint.'
                }
            }
        }
    }

    Invoke-TestCase -Run $run -Name 'service path matching uses a literal 360 path segment' -Test {
        $services = @(
            [pscustomobject]@{ Name = 'fixture-segment'; PathName = '"C:\Issue3Fixture\360\x.exe" --service' },
            [pscustomobject]@{ Name = 'fixture-prefixed-segment'; PathName = '"C:\Issue3Fixture\360DrvMgr\x.exe" --service' },
            [pscustomobject]@{ Name = 'fixture-octal'; PathName = '"C:\Issue3Fixture\fooðbar\x.exe" --service' },
            [pscustomobject]@{ Name = 'fixture-embedded'; PathName = '"C:\Issue3Fixture\abc360helper\x.exe" --service' },
            [pscustomobject]@{ Name = 'fixture-argument'; PathName = '"C:\Issue3Fixture\ordinary.exe" --angle 360' }
        )
        $fake = New-Fake360CleanupRuntimeProvider -Services $services

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $serviceFindings = @($findings | Where-Object { $_.Kind -eq 'Service' } | Sort-Object Name)
        Assert-TestEqual -Expected 2 -Actual $serviceFindings.Count `
            -Message 'The service path boundary produced a missed match or numeric false positive.'
        Assert-TestSequenceEqual -Expected @('fixture-prefixed-segment', 'fixture-segment') `
            -Actual @($serviceFindings.Name) `
            -Message 'The detector did not select the literal and product-prefixed 360 path segments.'
        foreach ($serviceFinding in $serviceFindings) {
            Assert-TestEqual -Expected 'ReviewOnly' -Actual $serviceFinding.Confidence `
                -Message 'A path-name-only service match must stay review-only.'
            Assert-TestEqual -Expected 'None' -Actual $serviceFinding.RemovalType `
                -Message 'A path-name-only service match must not become removable.'
        }
    }

    Invoke-TestCase -Run $run -Name 'confirmed winToolBox surfaces sibling services without approving removal' -Test {
        $toolboxRoot = Join-Path $script:KnownFolders.LocalAppData 'winToolBox'
        $softMgrRoot = Join-Path $toolboxRoot 'Tools\SoftMgrFixture'
        $softMgrMarker = Join-Path $softMgrRoot '360Base.dll'
        New-Item -ItemType Directory -Path $softMgrRoot -Force | Out-Null
        Set-Content -LiteralPath $softMgrMarker -Value 'ISOLATED-TOOLBOX-MARKER'

        $serviceLayouts = @(
            [pscustomobject]@{ Name = 'WinToolBoxUpdateSrv'; RelativePath = 'winToolBoxSrv.exe'; ExpectedConfidence = 'Confirmed'; ExpectedRemoval = 'Service' },
            [pscustomobject]@{ Name = 'KaoZipUpdateSrv'; RelativePath = 'Tools\zip\kUpdateSrv2.exe'; ExpectedConfidence = 'ReviewOnly'; ExpectedRemoval = 'None' },
            [pscustomobject]@{ Name = 'CClearUpdateSrv'; RelativePath = 'Tools\clear\cClearSvr.exe'; ExpectedConfidence = 'ReviewOnly'; ExpectedRemoval = 'None' },
            [pscustomobject]@{ Name = 'pdfReaderUpdateSrv'; RelativePath = 'Tools\pdf\pdfReaderSrv.exe'; ExpectedConfidence = 'ReviewOnly'; ExpectedRemoval = 'None' },
            [pscustomobject]@{ Name = 'WinInterceptUpdateSrv'; RelativePath = 'Tools\LockScreen\winInterceptSer.exe'; ExpectedConfidence = 'ReviewOnly'; ExpectedRemoval = 'None' }
        )
        $services = @($serviceLayouts | ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                PathName = ('"{0}" --service' -f (Join-Path $toolboxRoot $_.RelativePath))
                StartName = 'LocalSystem'
                ServiceType = 'Own Process'
                StartMode = 'Auto'
            }
        })
        $fake = New-Fake360CleanupRuntimeProvider -ProductEvidencePaths @($softMgrMarker) -Services $services

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        foreach ($layout in $serviceLayouts) {
            $serviceFinding = @($findings | Where-Object {
                $_.Kind -eq 'Service' -and $_.Name -eq $layout.Name
            })
            Assert-TestEqual -Expected 1 -Actual $serviceFinding.Count `
                -Message ("The {0} toolbox service was not surfaced exactly once." -f $layout.Name)
            Assert-TestEqual -Expected $layout.ExpectedConfidence -Actual $serviceFinding[0].Confidence `
                -Message ("The {0} toolbox service received the wrong confidence." -f $layout.Name)
            Assert-TestEqual -Expected $layout.ExpectedRemoval -Actual $serviceFinding[0].RemovalType `
                -Message ("The {0} toolbox service received the wrong removal type." -f $layout.Name)
        }
    }

    Invoke-TestCase -Run $run -Name 'winToolBox service visibility requires confirmation and an exact root boundary' -Test {
        $toolboxRoot = Join-Path $script:KnownFolders.LocalAppData 'winToolBox'
        $softMgrRoot = Join-Path $toolboxRoot 'Tools\SoftMgrFixture'
        $softMgrMarker = Join-Path $softMgrRoot '360Conf.dll'
        New-Item -ItemType Directory -Path $softMgrRoot -Force | Out-Null
        Set-Content -LiteralPath $softMgrMarker -Value 'ISOLATED-TOOLBOX-BOUNDARY-MARKER'

        $insideService = [pscustomobject]@{
            Name = 'CClearUpdateSrv'; PathName = ('"{0}" --service' -f (Join-Path $toolboxRoot 'Tools\clear\cClearSvr.exe'))
            StartName = 'LocalSystem'; ServiceType = 'Own Process'; StartMode = 'Auto'
        }
        $prefixedService = [pscustomobject]@{
            Name = 'KaoZipUpdateSrv'; PathName = ('"{0}" --service' -f (Join-Path ($toolboxRoot + '-backup') 'Tools\zip\kUpdateSrv2.exe'))
            StartName = 'LocalSystem'; ServiceType = 'Own Process'; StartMode = 'Auto'
        }

        $unconfirmedFake = New-Fake360CleanupRuntimeProvider -Services @($insideService)
        Set-360CleanupRuntimeProvider -Provider $unconfirmedFake.Provider -Context $unconfirmedFake.Context
        try {
            $unconfirmedFindings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        Assert-TestEqual -Expected 0 -Actual @($unconfirmedFindings | Where-Object {
            $_.Kind -eq 'Service' -and $_.Name -eq $insideService.Name
        }).Count -Message 'A toolbox path alone surfaced a service before the mixed bundle was confirmed.'

        $confirmedFake = New-Fake360CleanupRuntimeProvider -ProductEvidencePaths @($softMgrMarker) `
            -Services @($insideService, $prefixedService)
        Set-360CleanupRuntimeProvider -Provider $confirmedFake.Provider -Context $confirmedFake.Context
        try {
            $confirmedFindings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }
        Assert-TestEqual -Expected 1 -Actual @($confirmedFindings | Where-Object {
            $_.Kind -eq 'Service' -and $_.Name -eq $insideService.Name -and
            $_.Confidence -eq 'ReviewOnly' -and $_.RemovalType -eq 'None'
        }).Count -Message 'The in-root sibling toolbox service was not surfaced as review-only.'
        Assert-TestEqual -Expected 0 -Actual @($confirmedFindings | Where-Object {
            $_.Kind -eq 'Service' -and $_.Name -eq $prefixedService.Name
        }).Count -Message 'A path sharing only the winToolBox prefix crossed the exact root boundary.'
    }

    Invoke-TestCase -Run $run -Name 'detectors consume the injected discovery provider' -Test {
        $uninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
        $uninstallKey = $uninstallRoot + '\FixtureProduct'
        $task = [pscustomobject]@{
            TaskName = '360 Fixture Review Task'
            TaskPath = '\Fixture\'
            Actions  = @([pscustomobject]@{ Execute = 'C:\Fixture\ordinary-task.exe' })
        }
        $service = [pscustomobject]@{
            Name     = '360FixtureReviewService'
            PathName = '"C:\Fixture\ordinary-service.exe" --service'
        }
        $fake = New-Fake360CleanupRuntimeProvider `
            -RegistrySubKeys @{
                $uninstallRoot = @([pscustomobject]@{ PSPath = $uninstallKey })
            } `
            -RegistryValues @{
                $uninstallKey = [pscustomobject]@{
                    DisplayName     = 'Unrelated Fixture Product'
                    Publisher       = 'Fixture Publisher'
                    InstallLocation = 'C:\Fixture\Product'
                }
            } `
            -ScheduledTasks @($task) -Services @($service) -Processes @()

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $taskFinding = @($findings | Where-Object {
            $_.Kind -eq 'ScheduledTask' -and $_.Name -eq $task.TaskName
        })
        Assert-TestEqual -Expected 1 -Actual $taskFinding.Count `
            -Message 'The fake scheduled task was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $taskFinding[0].Confidence `
            -Message 'A name-only scheduled task match must stay review-only.'

        $serviceFinding = @($findings | Where-Object {
            $_.Kind -eq 'Service' -and $_.Name -eq $service.Name
        })
        Assert-TestEqual -Expected 1 -Actual $serviceFinding.Count `
            -Message 'The fake service was not surfaced exactly once.'
        Assert-TestEqual -Expected 'ReviewOnly' -Actual $serviceFinding[0].Confidence `
            -Message 'A name-only service match must stay review-only.'

        $subKeyCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistrySubKeys')
        $valueCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues')
        Assert-TestEqual -Expected 1 -Actual $subKeyCalls.Count `
            -Message 'The configured uninstall root must be enumerated once.'
        Assert-TestEqual -Expected $uninstallRoot -Actual $subKeyCalls[0].Arguments[0] `
            -Message 'The detector enumerated the wrong registry root.'
        Assert-TestEqual -Expected 1 -Actual $valueCalls.Count `
            -Message 'The configured uninstall record must be read once.'
        Assert-TestEqual -Expected $uninstallKey -Actual $valueCalls[0].Arguments[0] `
            -Message 'The detector read the wrong registry record.'

        foreach ($operation in @('ScheduledTasks', 'Services', 'Processes')) {
            $calls = @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation)
            Assert-TestEqual -Expected 1 -Actual $calls.Count `
                -Message ("The {0} provider operation must be called once per scan." -f $operation)
            Assert-TestEqual -Expected 0 -Actual $calls[0].Arguments.Count `
                -Message ("The {0} provider operation received unexpected arguments." -f $operation)
        }
    }

    Invoke-TestCase -Run $run -Name 'startup and process discovery use the injected provider data' -Test {
        $confirmedRoot = Join-Path $script:KnownFolders.Temp 'duohuipingbao'
        New-Item -ItemType Directory -Path $confirmedRoot -Force | Out-Null
        $executable = Join-Path $confirmedRoot 'duohuipingbao.exe'
        Set-Content -LiteralPath $executable -Value 'ISOLATED-MARKER'
        Set-Content -LiteralPath (Join-Path $confirmedRoot 'huabaosetup.exe') -Value 'ISOLATED-MARKER'

        $runRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $process = [pscustomobject]@{
            Name           = 'duohuipingbao.exe'
            ProcessId      = 4242
            ExecutablePath = $executable
        }
        $task = [pscustomobject]@{
            TaskName = 'FixtureDuohuiTask'
            TaskPath = '\Fixture\'
            Actions  = @([pscustomobject]@{
                Execute = $executable; Arguments = '--background'; WorkingDirectory = $confirmedRoot
            })
        }
        $service = [pscustomobject]@{
            Name = 'FixtureDuohuiService'; PathName = ('"{0}" --service' -f $executable)
            StartName = 'LocalSystem'; ServiceType = 'Own Process'; StartMode = 'Auto'
        }
        $fake = New-Fake360CleanupRuntimeProvider `
            -RegistryValues @{
                $runRoot = [pscustomobject]@{
                    FixtureStartup = ('"{0}" --background' -f $executable)
                }
            } `
            -ScheduledTasks @($task) -Services @($service) -Processes @($process)

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $startupFinding = @($findings | Where-Object {
            $_.Kind -eq 'Startup' -and $_.ValueName -eq 'FixtureStartup'
        })
        Assert-TestEqual -Expected 1 -Actual $startupFinding.Count `
            -Message 'The fake Run value was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $startupFinding[0].Confidence `
            -Message 'A Run executable under a confirmed fixture root was not confirmed.'
        Assert-TestEqual -Expected 'RegistryValue' -Actual $startupFinding[0].RemovalType `
            -Message 'The fake Run value did not preserve its removal type.'
        Assert-TestTrue -Condition ([string]$startupFinding[0].IdentityFingerprint -cmatch '^[0-9A-F]{64}$') `
            -Message 'A confirmed registry value did not capture an uppercase identity fingerprint.'

        $taskFinding = @($findings | Where-Object {
            $_.Kind -eq 'ScheduledTask' -and $_.Target -eq $task.TaskName
        })
        Assert-TestEqual -Expected 1 -Actual $taskFinding.Count `
            -Message 'The confirmed fake task was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $taskFinding[0].Confidence `
            -Message 'A task under a confirmed fixture root was not confirmed.'
        Assert-TestEqual -Expected 'Task' -Actual $taskFinding[0].RemovalType `
            -Message 'The confirmed fake task did not preserve its removal type.'
        Assert-TestTrue -Condition ([string]$taskFinding[0].IdentityFingerprint -cmatch '^[0-9A-F]{64}$') `
            -Message 'A confirmed task did not capture an uppercase identity fingerprint.'

        $serviceFinding = @($findings | Where-Object {
            $_.Kind -eq 'Service' -and $_.Target -eq $service.Name
        })
        Assert-TestEqual -Expected 1 -Actual $serviceFinding.Count `
            -Message 'The confirmed fake service was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $serviceFinding[0].Confidence `
            -Message 'A service under a confirmed fixture root was not confirmed.'
        Assert-TestEqual -Expected 'Service' -Actual $serviceFinding[0].RemovalType `
            -Message 'The confirmed fake service did not preserve its removal type.'
        Assert-TestTrue -Condition ([string]$serviceFinding[0].IdentityFingerprint -cmatch '^[0-9A-F]{64}$') `
            -Message 'A confirmed service did not capture an uppercase identity fingerprint.'

        $processFinding = @($findings | Where-Object {
            $_.Kind -eq 'Process' -and $_.Target -eq '4242'
        })
        Assert-TestEqual -Expected 1 -Actual $processFinding.Count `
            -Message 'The fake process was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $processFinding[0].Confidence `
            -Message 'A process under a confirmed fixture root was not confirmed.'
        Assert-TestEqual -Expected 'Process' -Actual $processFinding[0].RemovalType `
            -Message 'The fake process did not preserve its removal type.'

        $runValueCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues' | Where-Object {
            $_.Arguments[0] -eq $runRoot
        })
        Assert-TestEqual -Expected 1 -Actual $runValueCalls.Count `
            -Message 'The configured Run root attribution and identity must use one provider snapshot.'
        foreach ($operation in @('ScheduledTasks', 'Services')) {
            $identityCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation $operation)
            Assert-TestEqual -Expected 1 -Actual $identityCalls.Count `
                -Message ("The {0} attribution and identity must use one provider snapshot." -f $operation)
        }
        $processCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'Processes')
        Assert-TestEqual -Expected 1 -Actual $processCalls.Count `
            -Message 'The process provider operation must be called once per scan.'
    }

    Invoke-TestCase -Run $run -Name 'startup attribution and fingerprint come from one registry snapshot' -Test {
        $confirmedRoot = Join-Path $script:KnownFolders.Temp 'duohuipingbao'
        New-Item -ItemType Directory -Path $confirmedRoot -Force | Out-Null
        $originalExecutable = Join-Path $confirmedRoot 'duohuipingbao.exe'
        Set-Content -LiteralPath $originalExecutable -Value 'ISOLATED-RACE-MARKER'
        Set-Content -LiteralPath (Join-Path $confirmedRoot 'huabaosetup.exe') `
            -Value 'ISOLATED-RACE-MARKER'

        $runRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $firstSnapshot = [pscustomobject]@{
            FixtureRacingStartup = ('"{0}" --original' -f $originalExecutable)
        }
        $replacementSnapshot = [pscustomobject]@{
            FixtureRacingStartup = 'C:\UnrelatedFixture\replacement.exe --changed'
        }
        $firstProperty = $firstSnapshot.PSObject.Properties['FixtureRacingStartup']
        $firstToken = Join-360CleanupStableFields @(
            [string]$firstProperty.Name,
            [string]$firstProperty.TypeNameOfValue,
            (ConvertTo-360CleanupStableValue $firstProperty.Value)
        )
        $expectedFingerprint = Get-360CleanupTextSha256 $firstToken
        $replacementProperty = $replacementSnapshot.PSObject.Properties['FixtureRacingStartup']
        $replacementToken = Join-360CleanupStableFields @(
            [string]$replacementProperty.Name,
            [string]$replacementProperty.TypeNameOfValue,
            (ConvertTo-360CleanupStableValue $replacementProperty.Value)
        )
        $replacementFingerprint = Get-360CleanupTextSha256 $replacementToken
        $registryBehavior = {
            param($Context, $Path)
            $Context.RacingRegistryReads++
            if ($Context.RacingRegistryReads -eq 1) { return $firstSnapshot }
            return $replacementSnapshot
        }.GetNewClosure()
        $registryValues = @{}
        $registryValues[$runRoot] = $registryBehavior
        $fake = New-Fake360CleanupRuntimeProvider -RegistryValues $registryValues
        $fake.Context | Add-Member -MemberType NoteProperty -Name RacingRegistryReads -Value 0

        Set-360CleanupRuntimeProvider -Provider $fake.Provider -Context $fake.Context
        try {
            $findings = @(Get-360Findings)
        }
        finally {
            Reset-360CleanupRuntimeProvider
        }

        $finding = @($findings | Where-Object {
            $_.Kind -eq 'Startup' -and $_.Target -eq $runRoot -and
            $_.ValueName -eq 'FixtureRacingStartup'
        })
        Assert-TestEqual -Expected 1 -Actual $finding.Count `
            -Message 'The racing startup fixture was not surfaced exactly once.'
        Assert-TestEqual -Expected 'Confirmed' -Actual $finding[0].Confidence `
            -Message 'The original confirmed startup snapshot was unexpectedly downgraded.'
        Assert-TestEqual -Expected $expectedFingerprint -Actual $finding[0].IdentityFingerprint `
            -Message 'The startup fingerprint did not describe the same snapshot used for attribution.'
        Assert-TestFalse -Condition ($finding[0].IdentityFingerprint -eq $replacementFingerprint) `
            -Message 'A later replacement identity was combined with earlier confirmed attribution.'
        $runValueCalls = @(Get-Fake360CleanupCalls -Fake $fake -Operation 'RegistryValues' | Where-Object {
            $_.Arguments[0] -eq $runRoot
        })
        Assert-TestEqual -Expected 1 -Actual $runValueCalls.Count `
            -Message 'Startup attribution and fingerprinting performed separate provider reads.'
    }

    Complete-TestRun -Run $run
}
finally {
    if ($libraryLoaded) {
        Reset-360CleanupRuntimeProvider
    }
    if ($null -ne $originalKnownFolders) {
        $script:KnownFolders = $originalKnownFolders
    }
    if ($fixtureRoot -and (Test-Path -LiteralPath $fixtureRoot)) {
        Remove-TestDirectory -Path $fixtureRoot
    }
}
