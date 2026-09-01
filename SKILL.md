---
name: windows-360-cleaner
description: Audit and safely remove confirmed 360/Qihoo Windows software, including browsers and security products, SoftMgr download components, Huabao/duohuipingbao screen savers, persistence, and leftovers. Use when a user asks to find, explain, uninstall, or clean 360-family software from Windows. Do not use for generic malware cleanup or deleting every path containing the number 360.
---

# Windows 360 Cleaner Skill

This repository is an agent skill package, not a standalone cleanup application. Use its PowerShell scripts as deterministic supporting resources to identify and remove 360/Qihoo software without confusing unrelated files, games, drivers, or ordinary uses of the number `360` with a 360 product.

## Safety rules

1. Scan before changing anything. Run `scripts/Invoke-360Cleanup.ps1 -Mode Scan` and inspect the findings.
2. Explain the exact confirmed targets and obtain approval immediately before removal. A request to diagnose does not authorize deletion.
3. Never delete by a broad `*360*` search. Validate an exact path, installed-product record, executable path, service action, task action, digital signature, or product fingerprint.
4. Do not touch Windows screen savers, GPU/device drivers, Driver Genius (驱动精灵), games, 360-degree media, hashes, or numeric asset directories merely because their names contain `360`.
5. Restrict process termination to executables under confirmed target paths. Never kill a process because its command line contains a search term; the auditing shell itself may contain that term.
6. Treat other mounted Windows installations as scan-only. The bundled script intentionally has no offline remove mode; a separate approval does not authorize bypassing that boundary.
7. `winToolBox` is an Aolande/Huajun-family third-party toolbox, not a Microsoft or official 360 product. Treat it as PUP/bundleware only when local behavior supports that classification. Remove only a confirmed `SoftMgr*`/360 subtree, its updater persistence, and exact 360-linked updater binary. Preserve independent `kantu`, `clear`, `pdf`, and `zip` tools unless separately approved.
8. Preserve 360 browser profiles by default because they can contain bookmarks, history, sessions, and other user data. Use the separate profile opt-in only after the user approves that exact data loss.
9. Never overwrite an existing report or non-JSON file. Reports omit the local computer and user identity unless the user explicitly requests it.
10. Do not force-stop a normal application merely because it loaded a target DLL. Default to reboot-and-verify for locked targets; Explorer restart and ACL repair are separate advanced approvals.

## Workflow

### 1. Read the catalog when needed

Read [references/detection-catalog.md](references/detection-catalog.md) before expanding detection or deciding whether an ambiguous path is removable. It records confirmed paths, fingerprints, persistence mechanisms, WinToolBox ownership, and false positives.

### 2. Audit

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-360Cleanup.ps1 -Mode Scan
```

Report findings as:

- `Confirmed`: deterministic evidence permits removal after approval.
- `ReviewOnly`: suspicious, ambiguous, driver, or offline-system evidence that must not be automatically removed.

### 3. Explain persistence

When software reappears, correlate local timestamps and evidence. One observed chain was:

```text
Aolande/Huajun winToolBox updater
  -> SoftMgrUpdate*.exe scheduled task containing 360 components
  -> Temp\duohuipingbao\360hb_tmp\huabaosetup.exe
  -> AppData\Local\dhpingbao\duohuipingbao.exe
  -> Explorer-loaded qcnethelp/SoftMgrExt DLLs
```

Do not assert this chain unless the local service, task action, product metadata, digital signatures, or matching files support it.

### 4. Remove confirmed targets

After approval:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360
```

The script elevates through UAC when needed, records each action, and preserves review-only findings. It fails closed if a path is outside the exact allowlist, contains a reparse point, exceeds the target-count safety limit, or loses its evidence.

Do not add `-IncludeBrowserProfiles` unless the user separately approves deleting browser data after backing up anything needed. That opt-in also requires `-BrowserProfileConfirmation DELETE-360-BROWSER-DATA`.

Default removal does not restart Explorer, force-stop normal applications that loaded a target DLL, or take ownership of locked files. Read [references/troubleshooting.md](references/troubleshooting.md) before considering `-AllowExplorerRestart` or `-ForceLockedTargets`, explain the exact target and risk, and obtain a fresh approval.

### 5. Verify

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-360Cleanup.ps1 -Mode Verify
```

Recommend one restart after deleting services or Explorer extensions, then scan again. If a target returns, re-audit the new file creation times, parent process, service, task, and startup source instead of repeatedly deleting only the payload.

### 6. Report the measured outcome

After removal, retain `Summary` from the Remove JSON report and keep `Actions` available for item-by-item auditing. The file, directory, and logical-byte totals are measured from deduplicated before-and-after path snapshots; do not describe logical bytes as actual freed disk space because hard links, sparse files, and compression can make them differ. When `PathAccountingComplete` is false, present path totals as minimum confirmed values. After running Verify, use its `Findings`—not its null `Summary`—for the final post-restart confirmed count.

## Special situations

- For `Access denied` or Explorer shell-extension locks, read [references/troubleshooting.md](references/troubleshooting.md).
- For another mounted Windows installation, pass `-OfflineWindowsRoot F:\` in `Scan` mode. Offline findings are report-only.
- If the scan report contains a browser profile, keep it `ReviewOnly` unless the user explicitly chooses profile deletion.
- Remove an orphan uninstall key only after verifying its install location no longer exists.
- Prefer a functioning vendor uninstaller first; use deterministic cleanup for leftovers and broken uninstallers.

## Required final output

Lead with what was found, distinguish confirmed from review-only items, state exactly what will be removed, and mention preserved software. After deletion and verification, always report every value below from `Summary`, including zero values:

- `TotalItemsRemoved`, `FilesRemoved`, `DirectoriesRemoved`, `LogicalBytesRemoved`, and `LogicalSizeRemoved`.
- `ServicesRemoved`, `ServicesPendingRemoval`, `ScheduledTasksRemoved`, `RegistryKeysRemoved`, and `RegistryValuesRemoved`.
- `ProcessesStopped`, `SkippedActions`, `FailedActions`, `PendingActions`, `RetryAttempts`, and `UnresolvedRetryTargets`.
- `PathTargetsRemoved`, `PartiallyCleanedPathTargets`, `ImmediateRemainingConfirmed`, `NoImmediateConfirmedFindings`, and `PathAccountingComplete`.

If `PathAccountingComplete` is false, say that the path totals are minimum confirmed values and include `UnmeasuredPathTargets`. Then report the final count of `Confirmed` items from the Verify report's `Findings`. Say whether deletion was permanent, whether services are pending removal, whether anything remains, and whether a Windows restart is recommended. Never finish with only a vague statement such as “cleanup completed.”
