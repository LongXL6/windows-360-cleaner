---
name: windows-360-cleaner
description: Audit and safely remove confirmed 360/Qihoo Windows software, including browsers and security products, SoftMgr download components, Huabao/duohuipingbao screen savers, persistence, and leftovers. Use when a user asks to find, explain, uninstall, or clean 360-family software from Windows. Do not use for generic malware cleanup or deleting every path containing the number 360.
---

# Windows 360 Cleaner

Use this skill to identify and remove 360/Qihoo software without confusing unrelated files, games, drivers, or ordinary uses of the number `360` with a 360 product.

## Safety rules

1. Scan before changing anything. Run `scripts/Invoke-360Cleanup.ps1 -Mode Scan` and inspect the findings.
2. Explain the exact confirmed targets and obtain approval immediately before removal. A request to diagnose does not authorize deletion.
3. Never delete by a broad `*360*` search. Validate an exact path, installed-product record, executable path, service action, task action, digital signature, or product fingerprint.
4. Do not touch Windows screen savers, GPU/device drivers, Driver Genius (驱动精灵), games, 360-degree media, hashes, or numeric asset directories merely because their names contain `360`.
5. Restrict process termination to executables under confirmed target paths. Never kill a process because its command line contains a search term; the auditing shell itself may contain that term.
6. Treat other mounted Windows installations as scan-only unless the user separately approves a named offline Windows root.
7. `winToolBox` is an Aolande/Huajun-family third-party toolbox, not a Microsoft or official 360 product. Treat it as PUP/bundleware only when local behavior supports that classification. Remove only a confirmed `SoftMgr*`/360 subtree, its updater persistence, and exact 360-linked updater binary. Preserve independent `kantu`, `clear`, `pdf`, and `zip` tools unless separately approved.

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ConfirmRemoval
```

The script elevates through UAC when needed, records each action, releases Explorer DLL locks only when their full paths fall under confirmed targets, and preserves review-only findings.

### 5. Verify

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Invoke-360Cleanup.ps1 -Mode Verify
```

Recommend one restart after deleting services or Explorer extensions, then scan again. If a target returns, re-audit the new file creation times, parent process, service, task, and startup source instead of repeatedly deleting only the payload.

## Special situations

- For `Access denied` or Explorer shell-extension locks, read [references/troubleshooting.md](references/troubleshooting.md).
- For another mounted Windows installation, pass `-OfflineWindowsRoot F:\` in `Scan` mode. Offline findings are report-only.
- Remove an orphan uninstall key only after verifying its install location no longer exists.
- Prefer a functioning vendor uninstaller first; use deterministic cleanup for leftovers and broken uninstallers.

## Communication

Lead with what was found, distinguish confirmed from review-only items, state exactly what will be removed, and mention preserved software. After deletion, report whether files were permanently removed and whether a restart is recommended.

