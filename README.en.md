<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong> · <a href="https://longxl6.github.io/windows-360-cleaner/en/">Project website</a>
</p>

<p align="center">
  <img src="assets/readme/windows-360-cleaner-hero.jpg" alt="An AI agent scans, reviews, safely removes, and verifies Windows software" width="100%">
</p>

<h1 align="center">Windows 360 Cleaner: scan and remove 360/Qihoo software</h1>

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
> This open-source **AI agent skill package** includes Windows PowerShell scripts. Use an agent for guidance or double-click a script yourself. It supports Windows 10/11 and PowerShell 5.1+; no paid service is required.

## First time? Start with a scan report

1. [Download the repository ZIP](https://github.com/LongXL6/windows-360-cleaner/archive/refs/heads/main.zip), choose **Extract All**, and open the extracted folder.
2. Open `scripts` and double-click **`Scan-360.cmd`**. It does not remove software or require administrator access; it writes a JSON report when finished.
3. Find the file shown beside **`Report:`** in the window (on the Desktop by default). Read the results before deciding whether to continue.

**Getting the scan report completes the first step.** `Confirmed` means matching evidence was found, not that removal is approved. `ReviewOnly` means manual review only. Stop here if anything is unclear.

[Beginner steps and common questions](references/getting-started.en.md) · [Agent guidance](references/doubao.md) · [Ask for help with redacted details](https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml)

Browser profiles are preserved by default. Later removal is permanent, so back up important data before approval. Reports can contain personal paths: share a redacted copy and keep the original local Scan JSON unchanged.

## Already using an agent?

Copy this entire prompt to your agent:

```text
Use https://github.com/LongXL6/windows-360-cleaner and read the complete SKILL.md first.
Check whether you can access this Windows PC's terminal. Run Scan only if you can; otherwise guide me to scripts\Scan-360.cmd.
Explain Confirmed, ReviewOnly, and preserved items, then stop for my explicit approval. Never delete by a broad 360 name match; preserve browser profiles by default.
After approval, use the same reviewed original Scan report. Run Verify after removal and report all metrics and unresolved items required by SKILL.md.
```

> [!WARNING]
> Never search for every filename containing `360` and force-delete the results. The number can legitimately occur in photos, games, models, hashes, and Windows files. This skill requires both an exact allowed path and local product evidence.

## Doubao and agents without Skill installation

Doubao supports file uploads, but terminal access varies by product version and mode. Use this capability-aware prompt:

```text
Read SKILL.md from https://github.com/LongXL6/windows-360-cleaner before doing anything.
First state whether you can actually access this Windows PC's local PowerShell session. If you can, run Scan only, explain Confirmed, ReviewOnly, and preserved items, then stop for my explicit approval.
If you cannot access the terminal, do not claim local execution. Ask me to extract the full ZIP and run scripts\Scan-360.cmd. Keep the original JSON locally; share only a separate redacted copy or excerpt with cloud services, and state that an excerpt cannot establish the full result.
Wait until I review the local original and explicitly approve. Then use that same unchanged original for Remove, never the redacted copy.
After removal, run Verify and redact a separate copy before any cloud upload. Report every field required by SKILL.md, including zero values; mark unavailable values as unknown rather than inventing them.
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
| Access denied is not success | Default removal skips only the exact path that cannot be fully inspected, continues other approved targets, and reports that attention is still required |
| Browser data protected | Profiles require a separate backup and explicit opt-in |
| Normal apps protected | Loading a target DLL does not automatically authorize force-stopping an unrelated application |
| Vendor uninstaller is identity-bound | Duohui's supported uninstaller requires a valid exact Qihoo Authenticode signer, approved exact path and SHA-256, and one built-in argument; registry command lines are never executed blindly |
| Same-name replacement protected | Stable fingerprints for approved services, tasks, registry values, and registry-key trees are rechecked before mutation; changed or unreadable identities require a fresh Scan approval |
| Offline Windows is scan-only | No cross-system removal mode exists |
| Reports cannot overwrite | New JSON files omit the separate ComputerName/User fields by default; paths and approval context can still identify the user |

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
- Independent `kantu`, `clear`, `pdf`, and `zip` tools under `winToolBox`; this tool has no option to remove those components.
- Browser profiles under `360se6\User Data`, `360Chrome\Chrome\User Data`, `360ChromeX\Chrome\User Data`, and the legacy `360browser` path; program directories are detected separately.
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

Remove can enable browser-profile deletion only when the approved Scan report used `-IncludeBrowserProfiles`; omitting it during Remove safely preserves those profiles. Advanced locked-target options require a fresh explanation and approval; read [troubleshooting](references/troubleshooting.md) first. For an `AccessDenied` path, `-ForceLockedTargets` runs last, repairs only an exact verified ACL frontier, and rescans the complete approved root before deletion. A reparse point or unknown inspection error still blocks that path.

</details>

## Result reporting

The Remove report's `Summary` measures the approved/current intersection and changes since approval, plus removed objects, files, directories, logical bytes, services, tasks, registry entries, processes, vendor-uninstaller outcomes, failures, pending actions, retries, and unresolved targets. It also records `PostVendorMutationBlocked` and `ImmediateRescanComplete`. Path totals are deduplicated before/after snapshots. Logical file size is not guaranteed freed disk space because hard links, sparse files, and compression can differ. If the immediate rescan is incomplete, the report Findings are only the last safe pre-mutation snapshot, current remaining state is unknown, and the run requires attention. The final post-restart result comes from Verify report `Findings`.

## Validate the skill package

This test creates and removes only isolated fixtures under the system temporary directory. It does not run Remove against real 360 software:

```powershell
.\scripts\Test-360Cleaner.ps1
```

GitHub Actions runs the same safety suite on every change.

## Sharing and publishing

Use the editable [X, Xiaohongshu, WeChat, and Douyin copy](references/social-sharing.md) to introduce the project. Keep the first action read-only scanning.

The bilingual [project website](https://longxl6.github.io/windows-360-cleaner/en/) is live on GitHub Pages. The [publishing and search guide](references/publishing.md) covers previewing `docs/`, maintaining pages and sharing details, and Search Console verification and sitemap submission. A live website does not by itself establish Google indexing.

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
