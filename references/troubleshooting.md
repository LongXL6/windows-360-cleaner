# Troubleshooting

Read this reference only when removal fails, the payload returns, or another Windows installation is involved.

## Access denied on qcnethelp or SoftMgrExt DLLs

Explorer may load `qcnethelp64.dll`, `xhqcnethelp64.dll`, `SoftMgrExt64.dll`, or `analyst.dll` as an extension.

1. Verify the DLL's full path is under a confirmed target.
2. Stop payload and updater services/tasks first so they cannot recreate it.
3. Identify the exact Explorer PID loading the target-path DLL.
4. Restart Explorer only when such a module is loaded.
5. Retry the exact target. If ACLs are broken, take ownership and grant Administrators full control only on that validated target.
6. Restore Explorer and verify.

Never take ownership of a user profile, drive root, Windows directory, or Program Files root.

## The screen saver returns

Deleting `%LOCALAPPDATA%\dhpingbao` alone is insufficient when an updater remains. Check:

1. Payload and temp creation timestamps.
2. `SoftMgrUpdate*` task actions and run times.
3. `WinToolBoxUpdateSrv` path and state.
4. Startup values `duohuipingbao` and `sesvc`.
5. Parent process and executable path of `duohuipingbao.exe` or `huabaosetup.exe`.
6. Roaming `greencore`/`SoftMgr*` caches and `%TEMP%\360hb_tmp`.

Remove the confirmed source before retrying the payload directory.

## Orphaned uninstall entry

Before removing an uninstall record, confirm its `InstallLocation` does not exist, no process uses it, and the exact key has been recorded. Remove only that key, then rescan.

## Multiple Windows installations

Use `-OfflineWindowsRoot F:\` only with `-Mode Scan`. Findings are `ReviewOnly`. Offline ACLs, user SIDs, drive-letter changes, and boot configuration make cross-system cleanup riskier.

## Process query matches the auditing shell

PowerShell's command line may contain `360`, `huabao`, or a target path. Killing by command-line regex can terminate the cleanup itself. Always filter by `ExecutablePath` under an exact confirmed target.

## No admin rights

Scan mode still covers current-user locations. Remove mode self-elevates through UAC. If elevation is denied, report that machine-level services, tasks, and Program Files targets were not changed.

