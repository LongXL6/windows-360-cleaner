# Troubleshooting

Read this reference only when removal fails, the payload returns, or another Windows installation is involved.

## Access denied or 360 self-protection

360 self-protection can deny access to `%ProgramFiles%\360\360Safe` or `%ProgramData%\360safe` even for an administrator. Prefer turning off self-protection inside the installed product or running its working vendor uninstaller, then scan again.

When the cleaner can validate the exact target and its parent chain but an ACL prevents complete tree inspection, default removal records that path as `AccessDenied`, skips it, and continues only with other approved targets. The result is incomplete and a later `Verify` should still report the remaining confirmed item. Do not describe the run as a complete cleanup.

`-ForceLockedTargets` is a separately approved last resort. It processes access-denied paths after the normal plan, never uses a broad recursive ACL command on an unverified tree, and performs a complete reparse-point scan after repair. If a junction, symbolic link, mount point, or unknown inspection error appears, that path is not deleted.

Explorer may load `qcnethelp64.dll`, `xhqcnethelp64.dll`, `SoftMgrExt64.dll`, or `analyst.dll` as an extension.

1. Verify the DLL's full path is under a confirmed target.
2. Stop payload and updater services/tasks first so they cannot recreate it.
3. Identify the exact Explorer PID loading the target-path DLL.
4. Default to rebooting and running `Verify`; do not force-stop a normal application that loaded the DLL.
5. Use `-AllowExplorerRestart` only after separately approving an Explorer restart and only when Explorer loaded a DLL under the exact target.
6. Retry without changing ACLs. If ACLs are still broken, use `-ForceLockedTargets` only after a fresh approval; the script validates the exact target before and after ACL repair.
7. Restore Explorer and verify.

Never take ownership of a user profile, drive root, Windows directory, or Program Files root.

If a target, its parent chain, or any descendant is a junction, symbolic link, mount point, or other reparse point, stop. Do not override this refusal; inspect the link and target separately.

## The screen saver returns

Deleting `%LOCALAPPDATA%\dhpingbao` alone is insufficient when an updater remains. Check:

1. Payload and temp creation timestamps.
2. `SoftMgrUpdate*` task actions and run times.
3. `WinToolBoxUpdateSrv` path and state.
4. Startup values `duohuipingbao` and `sesvc`.
5. Parent process and executable path of `duohuipingbao.exe` or `huabaosetup.exe`.
6. Roaming `greencore`/`SoftMgr*` caches and `%TEMP%\360hb_tmp`.

When Scan reports the separately hash-bound `%LOCALAPPDATA%\dhpingbao\huabaosetup.exe` vendor-uninstaller action, prefer that approved action before the deterministic leftover sweep. Execution also requires a valid Authenticode signature whose signer simple name exactly matches the cataloged Qihoo publisher, and that trust is checked again immediately before launch. The cleaner uses only the fixed `/uninstall:byUserName` argument and does not trust an arbitrary registry command line. A changed hash, signer, reparse point, metadata, post-run resource identity, timeout, surviving related process, or launch failure must remain visible as requiring attention.

Remove the confirmed source before retrying the payload directory. If the exact `duohuipingbao` uninstall record becomes orphaned afterward, scan and approve its exact HKCU leftovers separately; do not delete a GUID parent or a broad registry pattern.

## Orphaned uninstall entry

Before removing an uninstall record, confirm its `InstallLocation` does not exist, no process uses it, and the exact key has been recorded. Remove only that key, then rescan.

## Multiple Windows installations

Use `-OfflineWindowsRoot F:\` only with `-Mode Scan`. Findings are `ReviewOnly`. Offline ACLs, user SIDs, drive-letter changes, and boot configuration make cross-system cleanup riskier.

The bundled script intentionally has no offline remove mode. Cleaning another installation requires a separately designed and approved workflow; do not repurpose `-ForceLockedTargets` to bypass this boundary.

## Browser profile is still present

Only the `User Data` subtrees under `360se6`, `360Chrome`, and `360ChromeX`, plus the legacy `360browser` profile, are treated as browser data. They are `ReviewOnly` by default because they may contain bookmarks, history, sessions, and other user data. Browser `Application` directories are separate product findings and still require local 360/Qihoo file evidence. Back up needed data first. Only then, with a separate approval, use both `-IncludeBrowserProfiles` and `-BrowserProfileConfirmation DELETE-360-BROWSER-DATA`.

## Report path is rejected

Reports must use a new `.json` path. The script refuses to overwrite an existing file, even an older report, to prevent a typo from destroying a document. Pick a new filename or omit `-ReportPath` to generate a unique desktop report. Computer and user identity are omitted unless `-IncludeIdentityInReport` is explicitly requested.

## Process query matches the auditing shell

PowerShell's command line may contain `360`, `huabao`, or a target path. Killing by command-line regex can terminate the cleanup itself. Always filter by `ExecutablePath` under an exact confirmed target.

## No admin rights

Scan mode still covers current-user locations. Remove mode self-elevates through UAC. If elevation is denied, report that machine-level services, tasks, and Program Files targets were not changed.
