<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong>
</p>

<p align="center">
  <img src="assets/readme/windows-360-cleaner-hero.jpg" alt="An AI agent scans, reviews, safely removes, and verifies Windows software" width="100%">
</p>

<h1 align="center">Windows 360 Cleaner Skill</h1>

<p align="center">
  A safety-first skill package for Codex, Doubao, and other AI agents to audit and remove confirmed 360/Qihoo Windows software.<br>
  <strong>Scan first · Human approval · Exact removal · Reboot verification · Measured report</strong>
</p>

<p align="center">
  <a href="https://github.com/LongXL6/windows-360-cleaner/actions/workflows/validate.yml"><img src="https://github.com/LongXL6/windows-360-cleaner/actions/workflows/validate.yml/badge.svg" alt="Validate"></a>
  <img src="https://img.shields.io/badge/Agent-Skill-22c55e" alt="Agent Skill">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078d4" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-2563eb" alt="PowerShell 5.1+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-f59e0b" alt="MIT License"></a>
</p>

> [!IMPORTANT]
> This is an **AI agent skill package**, not a standalone cleaner application. The PowerShell files in `scripts/` are deterministic, auditable resources used by the skill.

## Start in 30 seconds

Copy this entire prompt to your agent:

```text
Treat https://github.com/LongXL6/windows-360-cleaner as an AI skill package, not as an ordinary cleanup utility.
Read the complete SKILL.md first and follow every safety boundary. Read references only when evidence or troubleshooting requires them.
Run Scan only. Explain Confirmed, ReviewOnly, preserved normal files, and preserved browser data. Stop and wait for my explicit approval before running Remove.
Never expand the allowlist, broadly delete paths containing 360, or remove files from an offline Windows installation.
After approved removal, retain the Remove JSON Summary, run Verify, and count remaining Confirmed findings from the Verify JSON Findings.
In the final answer, include every metric required by SKILL.md, even when its value is zero. Describe LogicalBytesRemoved as logical file size, not guaranteed freed disk space.
```

> [!WARNING]
> Never search for every filename containing `360` and force-delete the results. The number can legitimately occur in photos, games, models, hashes, and Windows files. This skill requires both an exact allowed path and local product evidence.

## Doubao and agents without Skill installation

Doubao supports file uploads, but terminal access varies by product version and mode. Use this capability-aware prompt:

```text
Read SKILL.md from https://github.com/LongXL6/windows-360-cleaner before doing anything.
First state whether you can actually access this Windows PC's local PowerShell session. If you can, run Scan only, explain Confirmed, ReviewOnly, and preserved items, then stop for my explicit approval.
If you cannot access the terminal, do not claim that you scanned or removed anything. Ask me to download the ZIP, run scripts\Scan-360.cmd, and upload the JSON report for interpretation.
Do not run or guide Remove until I explicitly approve after seeing the scan. After removal, run Verify and report every field required by SKILL.md, including zero values.
```

See the bilingual [Doubao and generic-agent guide](references/doubao.md) for manual fallback steps and upload privacy notes.

## What it provides

| Find the source | Protect normal data | Produce verifiable results |
|---|---|---|
| Detect 360 security products, browsers, Software Manager, Huabao/duohuipingbao screen savers, and supported download chains | Preserve ordinary numeric files, drivers, games, Windows screen savers, and browser profiles by default | Record actions in JSON and report removed, failed, pending, and remaining items |

## How it works

1. The agent reads `SKILL.md` and checks whether it can actually access local PowerShell.
2. `Scan` performs a read-only audit and separates `Confirmed` from `ReviewOnly` findings.
3. The user reviews exact targets and explicitly approves or refuses removal.
4. `Remove` acts only on targets that are both in the approved Scan report and still confirmed; `Verify` checks whether anything returns.

The core rule is simple: **an agent may scan and explain automatically, but it may not approve permanent deletion for the user.**

## Beginner safety controls

| Control | Behavior |
|---|---|
| Scan before removal | `Scan` is read-only; `Remove` requires the reviewed Scan JSON, a switch, exact phrase, approval, and administrator access |
| Ambiguity fails safe | Unsupported targets remain `ReviewOnly` |
| Broad paths rejected | Drive roots, Windows, user profiles, and whole Temp directories cannot become removal targets |
| Reparse-point defense | Junctions and symbolic links cause the target batch to fail closed |
| Browser data protected | Profiles require a separate backup and explicit opt-in |
| Normal apps protected | Loading a target DLL does not automatically authorize force-stopping an unrelated application |
| Offline Windows is scan-only | No cross-system removal mode exists |
| Reports cannot overwrite | JSON reports are created as new files and omit computer/user identity by default |

## What it checks

- 360 Security Guard, antivirus products, browsers, Software Manager, uninstall records, and supported install paths.
- `dhpingbao`, `duohuipingbao`, `huabao_tmp`, and `360hb_tmp` screen-saver components.
- `SoftMgrUpdate*` scheduled tasks and evidence-backed third-party toolbox download chains.
- Startup entries, services, and processes that point to confirmed targets.
- Explorer-loaded `qcnethelp64.dll`, `xhqcnethelp64.dll`, and `SoftMgrExt64.dll` locking modules.
- User-selected offline Windows volumes, always in report-only mode.

## What it does not remove by default

- Files or folders whose only evidence is the number `360` in their name.
- Built-in Windows screen savers such as `Bubbles.scr`, `PhotoScreensaver.scr`, and `scrnsave.scr`.
- Driver Genius, GPU/network drivers, games, and numeric Steam/iRacing assets.
- Independent `kantu`, `clear`, `pdf`, and `zip` tools under `winToolBox` without separate approval.
- Browser profiles under `360Chrome`, `360se6`, and `360browser`.
- Any file from another mounted Windows installation.

## Install as a Codex Skill

Copy the complete repository to:

```text
%USERPROFILE%\.codex\skills\windows-360-cleaner
```

Then ask Codex:

```text
$windows-360-cleaner Scan this PC for 360/Qihoo software first. Do not remove anything yet.
```

Agents that do not support `$skill-name` do not need a renamed repository or separate package. Give them the repository URL and require them to read [SKILL.md](SKILL.md) directly.

<details>
<summary><strong>Manual fallback without an agent</strong></summary>

1. Select **Code → Download ZIP** on GitHub and extract it.
2. Double-click `scripts\Scan-360.cmd`. It is read-only and does not require administrator access.
3. Review the generated JSON report.
4. Only after reviewing exact targets, double-click `scripts\Remove-360.cmd`, read the warnings, press `Y`, and enter `REMOVE-360`.
5. Drag the same reviewed Scan JSON into the window, press Enter, and accept UAC.
6. Review the actions, summary, and remaining findings replayed in the original window.
7. Restart Windows once and double-click `scripts\Verify-360.cmd`.

Removal is permanent and does not use the Recycle Bin. The Scan JSON is the exact approval contract: newly confirmed but unapproved findings are reported, not removed. An incorrect phrase, Enter, or `N` exits safely.

</details>

<details>
<summary><strong>PowerShell commands</strong></summary>

```powershell
# Read-only scan
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan

# Approved removal of confirmed targets
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ApprovedReport 'C:\path\to\approved-scan.json' `
  -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360

# High-risk browser-profile removal: first create and review a Scan report with the same opt-in
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -IncludeBrowserProfiles
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ApprovedReport 'C:\path\to\approved-scan.json' `
  -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 `
  -IncludeBrowserProfiles -BrowserProfileConfirmation DELETE-360-BROWSER-DATA

# Verification
.\scripts\Invoke-360Cleanup.ps1 -Mode Verify

# Scan another mounted Windows installation; removal is intentionally unavailable
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -OfflineWindowsRoot F:\
```

Remove can enable browser-profile deletion only when the approved Scan report used `-IncludeBrowserProfiles`; omitting it during Remove safely preserves those profiles. Advanced locked-target options require a fresh explanation and approval; read [troubleshooting](references/troubleshooting.md) first.

</details>

## Result reporting

The Remove report's `Summary` measures the approved/current intersection and changes since approval, plus removed objects, files, directories, logical bytes, services, tasks, registry entries, processes, failures, pending actions, retries, and unresolved targets. Path totals are deduplicated before/after snapshots. Logical file size is not guaranteed freed disk space because hard links, sparse files, and compression can differ. The final post-restart result comes from Verify report `Findings`.

## Validate the skill package

This test creates and removes only isolated fixtures under the system temporary directory. It does not run Remove against real 360 software:

```powershell
.\scripts\Test-360Cleaner.ps1
```

GitHub Actions runs the same safety suite on every change.

## Contact

For reproducible project problems, prefer a public [GitHub Issue](https://github.com/LongXL6/windows-360-cleaner/issues) so the solution can help others. To contact the author through WeChat, click or scan the QR code below.

<p align="center">
  <a href="assets/readme/wechat-longxl.jpg">
    <img src="assets/readme/wechat-longxl.jpg" alt="WeChat QR code for LONG XL" width="260">
  </a>
</p>

This is a personal contact channel. Never send passwords, verification codes, or unredacted private files. No paid remote-control service is offered through this repository.

## License

[MIT](LICENSE)
