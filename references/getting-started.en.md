# First scan with Windows 360 Cleaner

[Back to the project](../README.en.md) · [简体中文](getting-started.md)

Start by generating a report about supported 360/Qihoo software, Huabao or Duohui screen savers, and leftovers. **You can stop after scanning and reading the report.** Removal requires a separate decision.

You need Windows 10/11 and Windows PowerShell 5.1 or newer. A phone can display this guide, but the scripts run on the Windows PC you want to inspect. A chat assistant may not have access to that PC.

## 1. Download and extract everything

1. Open [LongXL6/windows-360-cleaner](https://github.com/LongXL6/windows-360-cleaner) and check the owner and repository name.
2. Choose **Code → Download ZIP**, or [download the main branch ZIP](https://github.com/LongXL6/windows-360-cleaner/archive/refs/heads/main.zip). Reading and downloading the public repository does not require a GitHub account.
3. Right-click the ZIP in File Explorer and choose **Extract All**. Open the extracted folder; it should contain `SKILL.md`, `scripts`, and `references`.
4. Open `scripts`. Keep `Scan-360.cmd` and `Invoke-360Cleanup.ps1` together. Do not run from the ZIP preview or download only the `.cmd` file.

This is a script package; there is no `.exe` installer to find. Downloading it does not start scanning or removal.

## 2. Double-click Scan

Run `scripts\Scan-360.cmd`. The window shows `Windows 360 Cleaner - Scan`, findings, and a **`Report:`** path ending in `.json`. Scan reads local state and creates a report without removing target software or requesting administrator access.

Reports normally go to the Windows Desktop with a name like `360-cleanup-report-date-time-random.json`. If Windows returns no Desktop path, the script uses the temporary directory. A redirected Desktop, including OneDrive, may also be elsewhere. **Use the actual `Report:` path shown in the window.**

The window waits for a key press at the end. Note the path before closing it. An error without a successfully written report does not mean the scan completed.

## 3. Read the result before deciding

Open the JSON with Notepad, or ask an agent with local file access to explain it. JSON is a text record, not a program to execute.

| Result | Meaning | Next step |
|---|---|---|
| `Confirmed` | Current rules found matching evidence | Read each `Name`, `Target`, and `Reason` and decide whether you want removal |
| `ReviewOnly` | Review only: ambiguous evidence, protected data, or offline-system objects | Leave it alone; ask for help if unclear |
| `No matching 360/Qihoo findings.` | No findings matched the current rules | You can stop; this is not an all-system security verdict |
| Access denied, errors, or incomplete inspection | Some state could not be read successfully | Keep the error and ask for help before trying anything else |

`Confirmed` is an evidence label, **not your approval**. Review the whole report. Browser bookmarks, history, and sessions are preserved by default. An ordinary photo, game, or folder is not a target merely because its name contains `360`.

An agent prompt:

```text
Read this project's SKILL.md, then explain this Scan report without deleting anything.
Separate Confirmed, ReviewOnly, and preserved items, and explain every proposed target and risk.
If this is a redacted excerpt, say that it cannot establish the full scan result. Wait for me to review the original report and decide.
```

### Keep the original report private

Omitting the separate `ComputerName` and `User` fields does **not** make a report anonymous. Paths, user SIDs, approval context, task arguments, and software names can still identify you.

- Keep the original Scan JSON unchanged on your PC. It is the approval input for Remove.
- For discussion, make a separate copy or excerpt and redact usernames, private paths, SIDs, and unrelated task arguments. Label it as a redacted excerpt, not a full result.
- Do not use the redacted copy for Remove or edit the original to select targets. The double-click workflow processes the approved findings in the whole report that are still Confirmed; it has no per-item selection UI.
- Decide what you are comfortable uploading before using a cloud assistant. You can also read the report locally without uploading it.

## 4. Remove only after approval

Back up important files and browser data. If a working vendor uninstall entry exists in Windows Installed apps, you can use it first and run a fresh Scan for leftovers.

Removal is permanent and does not use the Recycle Bin. Continue only after understanding and approving all proposed targets in the original Scan report. Stop if any target should stay.

1. Close the target software and related browsers.
2. Double-click `scripts\Remove-360.cmd`.
3. Read the warnings. To continue, press `Y`, then type **`REMOVE-360`** when asked.
4. Drag the same reviewed, unchanged original Scan JSON into the window and press Enter. Do not use a Verify report or a redacted copy.
5. If Windows requests administrator access, confirm it is for your action before deciding to allow it. Contact the PC administrator if you lack access.
6. Return to the original window for actions and `Removal summary`, and keep the new report. New unapproved targets are not automatically removed; skipped, failed, and pending items still need attention.

To cancel at the initial `Continue? [Y/N]` prompt, press `N`. The double-click confirmation is `REMOVE-360`; advanced PowerShell examples use a different phrase.

## 5. Restart and Verify

Save your work, restart Windows once, and run `scripts\Verify-360.cmd`. It performs a read-only check and creates another JSON file. Use each report's `Mode` field to distinguish `Scan`, `Remove`, and `Verify`.

- `Verification passed`: this Verify found zero Confirmed items. Review any ReviewOnly items separately; this does not guarantee that software cannot return.
- `confirmed finding(s) remain`: some targets remain. Ask for help with redacted findings, or run a fresh Scan and review it again before any new removal.
- `ImmediateRescanComplete` is `false` in Remove: immediate remaining state is unknown. Its saved Findings must not be treated as a post-removal result.

Logical file size is not guaranteed freed disk space. See [result reporting](../README.en.md#result-reporting) and [SKILL.md](../SKILL.md) for the full measurement rules.

## Common problems

| Problem | What to do |
|---|---|
| You are on a phone, macOS, or Linux | Download and extract the package on the Windows PC you want to inspect |
| Double-click fails, shows an error, or cannot find `.ps1` | Check that all files were extracted together; run Scan again and record the error |
| Windows or organization policy blocks it | Check the source and ask the administrator; do not disable protection or weaken global policy |
| No Desktop report or a write error | Follow the actual `Report:` path; share the error text if writing failed |
| An agent says it finished but shows no output or report | Ask whether it has local terminal access; run Scan yourself if it does not |
| Software returns after removal | Run a fresh Scan and review service/task/source evidence using [troubleshooting](troubleshooting.md) |

[Open a help issue](https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml) with your Windows version, the step, expected behavior, and a redacted error (GitHub sign-in required). Do not attach the original report. You can also use the [author contact](../README.en.md#contact).
