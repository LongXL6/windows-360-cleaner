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

## Scan or Verify says some checks did not complete

`ScanCoverage.Complete = false` means at least one read did not finish, for example the scheduled-task, service, or process list, the installed-program records, or a product folder that could not be listed. The findings that were read are still valid, but a result of “no findings” is not proof that nothing is installed. Read `ScanCoverage.Issues`, close security software prompts or reboot if a folder was locked, and scan again. Do not use force options or change ACLs just to make a scan complete; an unreadable product folder stays `ReviewOnly`.

## Verification after a partial cleanup

Run `-Mode Verify -PreviousRemoveReport <the Remove report>` (the guided window does this for “检查上次删除的结果” / “Check the last deletion”; in a conversation, run the `AGENT: after-restart=` command printed by `Show-360Summary.ps1`, or `Show-360Summary.ps1 -FindLastRemove` in a new conversation). Tell the user the result with `Show-360Summary.ps1 -Report <verify report> -Mode Verify -ExitCode <its exit code>`. The fields behind that summary are in `TaskVerification`:

- `Selected` items with `Absent` were proven gone by a direct read-only probe. `Remaining` or `Changed` means the selected target, or a changed resource with the same name, is still there. `Unknown` means the probe failed; do not treat it as removed.
- `Preserved` items are targets the user chose to keep. `Present` is the expected result and never fails the task. `Absent` usually means a vendor uninstaller or the user removed it separately.
- `New` items are Confirmed findings outside this task, such as software that was reinstalled. Start a fresh Scan and a fresh decision; never extend the old approval.
- `Unavailable` means the Remove report is missing, damaged, from another user, from an incompatible version, or from an earlier version that did not record the selection (`SelectionNotRecorded`). The global scan result is still shown.

Verify never deletes anything and never reuses the earlier approval.

## Guided window problems

- The window does not open: make sure the whole ZIP was extracted and `开始检查.cmd` sits next to the `scripts` folder. Run `scripts\Scan-360.cmd` to see console output.
- A second window refuses to open with “本工具已经打开了。” (The tool is already open.): only one guided window runs at a time. Find the first window in the taskbar, or close it first.
- Cancelling a check (停止检查 / Stop checking) stops only the read-only scan; its incomplete result is not used. A running removal cannot be cancelled from the window, and the window cannot be closed while it runs, so that no half-finished state is left behind.
- The window's home page (上次删除的记录 / Last deletion) only finds deletions made in the window, because only they leave a `360-cleanup-task-*.json` record. After a deletion made in an agent conversation, check it from the conversation (`Show-360Summary.ps1 -FindLastRemove`). The window never shows it: it starts a new check or, if an earlier deletion was made in the window, shows that older deletion (check the time on the card).
- Items that can never pass the selection check in this check result are shown as 不删除：里面有要保留的东西 (Won't delete: it holds things that are kept, a folder that contains content that must be kept) or 不删除：要和它所在的文件夹一起删 (Won't delete: it goes together with its folder, a vendor uninstaller whose install folder cannot be deleted). They cannot be ticked by row, product row checkbox or 全选可以删除的 (Select all deletable), are not counted as deletable, and the agent summary lists them the same way and never takes them with `-Delete`. This is expected; do not work around it.
- A product row checkbox can still leave out an item on purpose when it depends on another product that is not ticked (for example a folder that contains 360 items of another product). The sentence under the list names the first skipped item.
- When asking for help, use “获取帮助” (Get help). Review the preview for names, accounts, and private folders before sharing. The text is a separate redacted copy; it cannot authorize removal.

## Agent summary gives no conclusion or refuses a choice

`scripts/Show-360Summary.ps1` only reads reports and prints text. Its exit code says what happened:

- `2` (no conclusion): `-ExitCode` or `-ScanReportHash` is missing or invalid, the report is missing or unreadable and its step cannot be told (no `-Mode` and no `360-cleanup-scan|remove|verify-` file name), the report is of the wrong kind, or a value was given without its parameter name (for example `-Delete 1 2` instead of `-Delete 1,2`). Fix the command; never tell the user the step finished. A Remove or Verify summary always needs the exit code of the command that wrote the report, or `unknown` when it was lost.
- `3` (choice refused, no Remove command printed): an unknown number, only 不删除 (won't delete) products, more than 64 items, nothing left after the safety shrink, or the check result changed since the summary the user answered (show the new list and ask again). Tell the user the printed text and delete nothing.
- A folder name with `$`, a backtick, `%` or `!` makes the summary print `unsafe-path=true` and no command, because shells change those characters even inside quotes. One product with more than 64 items cannot be deleted in one conversation step. In both cases the user can delete in the window (`开始检查.cmd`), where they choose.
- A missing Remove report is never “nothing was deleted”: the summary says 不确定有没有删干净 (not sure everything was deleted) and leads to a restart and a new check. Never run the removal again.

## Report path is rejected

Reports must use a new `.json` path. The script refuses to overwrite an existing file, even an older report, to prevent a typo from destroying a document. Pick a new filename or omit `-ReportPath` to generate a unique desktop report. Computer and user identity are omitted unless `-IncludeIdentityInReport` is explicitly requested.

## Process query matches the auditing shell

PowerShell's command line may contain `360`, `huabao`, or a target path. Killing by command-line regex can terminate the cleanup itself. Always filter by `ExecutablePath` under an exact confirmed target.

## No admin rights

Scan mode still covers current-user locations. Remove mode self-elevates through UAC. If elevation is denied, report that machine-level services, tasks, and Program Files targets were not changed.
