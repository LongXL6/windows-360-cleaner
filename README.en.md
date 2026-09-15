<p align="center">
  <a href="README.md">简体中文</a> · <strong>English</strong> · <a href="https://longxl6.github.io/windows-360-cleaner/en/">Project website</a>
</p>

<p align="center">
  <img src="assets/readme/windows-360-cleaner-hero.jpg" alt="Illustration of the flow: check first, confirm, delete, then check again after a restart" width="100%">
</p>

<h1 align="center">Windows 360 Cleaner</h1>

<p align="center">
  An AI agent skill that finds 360-family software and what it left behind on your PC, tells you in plain words whether each one "can be deleted" or "won't be deleted", and deletes only what you confirm yourself<br>
  <strong>Check first · Hear what can go · Delete only after you confirm · Check again after a restart</strong>
</p>

<p align="center">
  <a href="https://github.com/LongXL6/windows-360-cleaner/actions/workflows/validate.yml"><img src="https://github.com/LongXL6/windows-360-cleaner/actions/workflows/validate.yml/badge.svg" alt="Validate"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/Version-1.0.0-0ea5e9" alt="Version 1.0.0"></a>
  <img src="https://img.shields.io/badge/Agent-Skill-22c55e" alt="Agent Skill">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078d4" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-2563eb" alt="PowerShell 5.1+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-f59e0b" alt="MIT License"></a>
</p>

<p align="center">
  Current version <strong>1.0.0</strong> · <a href="CHANGELOG.md">Changelog</a> · <a href="https://github.com/LongXL6/windows-360-cleaner/archive/refs/heads/main.zip">Download ZIP</a> · <a href="references/getting-started.en.md">Beginner guide</a>
</p>

**Jump to:** [What it is](#what-it-is) · [Requirements](#requirements) · [Download](#download) · [Use it with an AI agent (recommended)](#use-it-with-an-ai-agent-recommended) · [Agent cannot run commands: double-click Start-Check](#if-your-agent-cannot-run-local-commands-double-click-start-check) · [Window walkthrough](#window-walkthrough-from-checking-to-confirming-it-is-all-gone) · [FAQ](#faq) · [For maintainers](#for-maintainers-technical-details)

## What it is

This is a free, open-source **AI agent skill** that also comes with a local window. It checks your PC for 360-family software and what it left behind, tells you in plain words whether each one **can be deleted** or **won't be deleted**, and then **deletes only what you confirm yourself**.

There are two ways to use it, and both say exactly the same things:

| Your situation | How to use it |
|---|---|
| You use an AI agent that can run commands on this PC (for example Codex) | **Recommended.** Just tell the agent "check this PC for 360 software". It tells you what it suggests deleting and what won't be deleted, and deletes only after you confirm. See [Use it with an AI agent](#use-it-with-an-ai-agent-recommended) |
| Your agent cannot run local commands (for example Doubao on the web), or you do not use an agent | Download and extract the ZIP, then double-click **Start-Check**. Every row in the window says "Can be deleted" or "Won't delete: reason", and you tick and confirm yourself. See [Double-click Start-Check](#if-your-agent-cannot-run-local-commands-double-click-start-check) |

It can find:

- 360 Total Security and 360 Antivirus (360 安全卫士、360 杀毒)
- 360 Secure Browser, 360 Speed Browser, and 360 Speed Browser X
- 360 Software Manager (360 软件管家)
- 360 Huabao / Duohui screen saver (360 画报 / 多绘屏保)
- 360 program files bundled inside the third-party toolbox winToolBox
- programs that run at startup, background services, tasks that run on a timer, and similar items related to the software above

Remember three things:

- **Checking never deletes anything.**
- **Nothing is deleted without your explicit confirmation.** An agent may say "I suggest deleting it", and the window opens with nothing ticked; whether to delete, and what, is only your decision.
- **It never restarts your PC, never runs at startup, never stays in the background, and never uploads anything.**

It is not antivirus software. It does not remove viruses, and it does not delete ordinary files just because their names contain "360".

## Requirements

| Item | Details |
|---|---|
| System | Windows 10 or Windows 11 |
| What to install | Nothing. It uses the Windows PowerShell 5.1 that comes with Windows; just extract the ZIP and use it |
| AI agent (optional) | An agent that can run PowerShell on this PC can run the check for you and tell you the result in plain words. Web chatbots usually cannot; use the Start-Check window then |
| Administrator permission | Not needed to check. Windows asks for permission only when you confirm a deletion. If your PC has no administrator access, ask its administrator |
| Time | A check usually takes a minute or two, depending on the PC |
| Network | Needed to download the ZIP. The tool never uploads anything |
| Language | Window: Chinese when the Windows display language is Chinese, English otherwise. Agent: replies in the language you use |
| Which device | The Windows PC you want to check. A phone or Mac can only display these instructions |

## Download

**[Click here to download the ZIP](https://github.com/LongXL6/windows-360-cleaner/archive/refs/heads/main.zip)** (or click the green **Code** button at the top of this page, then **Download ZIP**).

- Downloading and reading need no GitHub account and cost nothing.
- Make sure the address is `github.com/LongXL6/windows-360-cleaner`. Do not download modified copies from other sites.
- After the maintainer publishes a release, you can also download a ZIP with the version number (named like `windows-360-cleaner-v1.0.0.zip`) from the [Releases page](https://github.com/LongXL6/windows-360-cleaner/releases).
- If you use an agent, it can also download this repository for you.
- Downloading the ZIP does not check or delete anything.

## Use it with an AI agent (recommended)

This repository is first of all an **AI agent skill**. The agent follows [SKILL.md](SKILL.md) to run the check, then uses `scripts\Show-360Summary.ps1` to turn the result into plain words for you. The agent and the window use the same texts, so all you hear is "can be deleted" or "won't be deleted", and why.

The core rule is one sentence: **an agent may check, explain and suggest, but only you say whether to delete and which items.**

<p align="center">
  <img src="assets/readme/how-it-works.svg" alt="Flow diagram (in Chinese): check first without deleting anything, say for each 360 product whether it can be deleted, you name the numbers and read the confirmation, you say &quot;yes, delete&quot; and Windows asks for permission, delete, then restart yourself and check again" width="100%">
</p>

### 1. Give the agent this skill

- **Codex**: copy the complete repository to `%USERPROFILE%\.codex\skills\windows-360-cleaner`, then say `$windows-360-cleaner check this PC for 360 software`.
- **Other agents that can run local commands**: send them the repository address `https://github.com/LongXL6/windows-360-cleaner` and ask them to read `SKILL.md` completely first.
- **Not sure whether your agent can run commands**: ask it "Can you run PowerShell on this Windows PC?". If it cannot, use the [Start-Check window](#if-your-agent-cannot-run-local-commands-double-click-start-check) below.

### 2. What to say to the agent

One sentence is enough:

```text
Check this PC for 360 software, tell me in plain words what you suggest deleting and what won't be deleted, and delete only what I confirm.
```

If you want the agent to follow the rules more strictly, copy the [full prompt](#copy-the-full-prompt-for-your-agent) below.

### 3. What the agent will reply

Here is an example conversation. The data is a sample; what the agent says comes from the real output of `Show-360Summary.ps1` (the agent may shorten it a little, and "I suggest deleting it" and "do you still use it?" are the agent's own suggestions):

```text
You:    Check this PC for 360 software

Agent:  The check is finished (checking never deletes anything). Found 2 product(s) from 360 with items that can be deleted:
        1. 360 Secure Browser - 1 can be deleted, 1 not
           Bookmarks and history won't be deleted. Do you still use 360 Secure Browser? If not, I suggest deleting it.
        2. 360 Huabao / Duohui screen saver - Can be deleted (3), I suggest deleting it
           After deleting: The Duohui screen saver and its wallpaper features cannot be used afterwards. The uninstaller that came with the Duohui screen saver is run; what it removes cannot be recovered.
        These won't be deleted:
        3. 360 temporary files - Won't delete: not sure it belongs to 360
        Which ones should be deleted? Just reply with the numbers, for example "delete 1" or "delete 1 and 2". Anything you do not name is kept.

You:    delete 2

Agent:  OK. Please take one more look before deleting:
        To delete (3): 360 Huabao / Duohui screen saver (installation folder, temporary installer files, run the uninstaller that came with it)
        After deleting: the installation folder and everything inside it are deleted, and the Duohui screen saver and its wallpaper features cannot be used afterwards; the temporary installer files are only temporary files; the uninstaller that came with the Duohui screen saver is run, and what it removes cannot be recovered.
        Not selected (this tool does not delete them): 360 Secure Browser, 360 temporary files
        Deleted items cannot be recovered and do not go to the Recycle Bin.
        Your selection includes an uninstaller that came with 360. It may also remove parts of the same product that you did not select.
        Close the 360 programs first, and back up bookmarks or other data you need.
        When deleting starts, if Windows asks for permission, click "Yes".
        Delete these items? Reply "yes, delete" and I will start.

You:    yes, delete

Agent:  Deletion complete
        Everything you selected was deleted. Because the uninstaller that came with 360 ran, parts of the same product that you did not select may have been removed too.
        3 deleted, 0 not deleted, 0 not sure.
        Next: When convenient, restart the PC once, after saving your work (I will not restart it for you). Tell me when it has restarted and I will check that everything is gone.

You:    It has restarted

Agent:  Everything selected last time is gone
        All 3 item(s) selected last time are confirmed gone. The items you kept are still there. That is expected.
        Next: There is nothing more to do.
```

### 4. What to know when you use an agent

- **"I suggest deleting it" is not a decision made for you.** Only the numbers you name are deleted; anything you do not name is kept. "Delete everything" only covers items marked "can be deleted", and the agent asks first about software you may still use (such as a browser or 360 Total Security).
- **The agent never suggests deleting anything marked "won't delete", and never looks for another way to delete it.**
- **You always see the confirmation text before anything is deleted.** The agent starts only after you explicitly reply "yes, delete". To change your choice, name the numbers again and it shows you the text again.
- When Windows asks for permission, make sure it is for the deletion you just agreed to, then click "Yes"; clicking "No" deletes nothing. The agent cannot confirm that you clicked "No", so it honestly says "Not sure everything was deleted" and asks you to restart and check again; just do that (checking never deletes anything).
- **Once deleting starts, it cannot be stopped**, and do not ask the agent to run it again.
- **The agent never restarts your PC.** Save your work, restart yourself, then tell it "it has restarted". If you are in a new conversation, say "check the last deletion"; it finds the record of the last deletion first and then checks. Checking never deletes anything.
- If something was not deleted, is not sure, or needs a restart, the agent must say so and must not call it finished. If an agent says it is done but cannot show a real check result, do not believe it.
- For details such as how many files were deleted and how large they were, just ask the agent for "details".
- If you deleted in a conversation, go back to the agent to check after the restart; the "Last deletion" page of the Start-Check window only remembers deletions made in the window. If that page appears anyway, it shows an earlier deletion made in the window, so check its time.

### Copy the full prompt for your agent

```text
Use https://github.com/LongXL6/windows-360-cleaner. Read the complete SKILL.md first, follow its safety rules, and talk to me the way its "Talking to the user" section describes.
First tell me whether you can really operate PowerShell on this Windows PC. If you cannot, do not claim that you checked anything; ask me to fully extract the ZIP and double-click 开始检查.cmd (or Start-Check.cmd) in the root folder.
If you can: run the check (Scan, which never deletes anything), then scripts\Show-360Summary.ps1, and tell me in its plain words for each 360 product "can be deleted" or "won't delete" and why. You may suggest deleting products that can be deleted; ask me first about the ones I may still use; never suggest deleting, or working around, anything marked "won't delete". Do not read AGENT: lines, paths or technical words to me.
I name the numbers to delete; anything I do not name is kept, and "delete everything" means only the items that can be deleted. Before deleting, show me the confirmation text Show-360Summary prints for my numbers and wait for my explicit "yes, delete"; then run the command it printed exactly once and never edit it. Never delete in bulk by names containing 360, and keep browser personal data by default.
After deleting, tell me the result with Show-360Summary and remind me to save my work and restart the PC myself; never restart automatically. After the restart, run the check (which never deletes anything) and tell me its result with Show-360Summary; in a new conversation, use -FindLastRemove to find the last deletion first.
Finish with a few sentences: what was deleted, what is left or not sure, and whether to restart and what comes next. Never present not deleted, not sure or restart-needed as finished; items I kept are not failures, and kept items that are gone must be mentioned. I will ask if I want detailed statistics.
```

The agent should read [SKILL.md](SKILL.md) first. It should read the [detection catalog](references/detection-catalog.md) only when it needs to judge detection evidence, and [troubleshooting](references/troubleshooting.md) only for locked files or access denied errors. Doubao and other agents that do not support `$skill-name` installation do not need a renamed skill: give them the repository URL and require them to read `SKILL.md` first.

### Doubao and other agents that cannot run local commands

Web chatbots such as Doubao usually cannot reach PowerShell on your PC, so they cannot check or delete anything for you. In that case, ask them to guide you to the [Start-Check window](#if-your-agent-cannot-run-local-commands-double-click-start-check): the window says in the same plain words whether each item "can be deleted" or "won't be deleted", and you tick and confirm in the window yourself. When you want the chatbot to look at a result, send it only the text created by "Get help" in the window, after checking it line by line; that text is only for discussion and can never be used to delete anything.

```text
Treat https://github.com/LongXL6/windows-360-cleaner as an AI skill package. First read SKILL.md in the repository root; do not rely on the README alone, and never search for and force-delete everything whose name contains 360.
Before starting, tell me clearly whether you can really access local PowerShell on this Windows PC and run commands. If you cannot, say so directly; do not present "suggested a command" as "already ran it".
If you cannot operate the PC: ask me to download and fully extract the ZIP, then double-click Start-Check (开始检查) in the root folder. Opening it checks first, deletes nothing, and ticks nothing. Help me understand the "Delete?" answer of each row in the window: "Can be deleted" means it is something 360 left behind that can be deleted; rows that say "Won't delete: reason" cannot be ticked. If I do not understand, remind me to tick nothing and just click "Close".
When I need to show you results, I will only send the text created by "Get help" in the window, after checking it line by line; the original record files stay on my PC. That text is only for discussion and can never be used to delete anything. You may tell me what you suggest deleting and what won't be deleted, but whether to delete is my decision, made by ticking and confirming in the window.
After deleting, remind me to save my work, restart the PC myself, double-click Start-Check again, and click "Check the last deletion". When explaining that check, items I kept are not failures, and anything that cannot be confirmed must be called not confirmed.
If you really can operate the terminal: run the check first and tell me with the plain words of scripts\Show-360Summary.ps1 what can be deleted and what won't be; before deleting, show me the confirmation text it prints for the numbers I named and wait for my explicit "yes, delete", then run the command it printed exactly once; after the restart, run the check and tell me its result with Show-360Summary. Finish with a few sentences on what was deleted, what is left or not sure, and what comes next, without inventing anything.
```

For more detailed routes, privacy notes about uploading content, and troubleshooting, see the [Doubao and generic-agent guide](references/doubao.md) (in Chinese, with an English prompt).

## If your agent cannot run local commands: double-click Start-Check

If you do not use an agent, or your agent cannot reach your PC, use the local window. It says the same things as the agent: every row only answers "Delete?".

1. Right-click the downloaded ZIP file, choose **Extract All** (on Chinese Windows: 全部解压缩, sometimes shown as 全部解压), and follow the prompts. **Do not run anything directly from inside the ZIP.**
2. Open the extracted folder until you can see `开始检查`, `Start-Check`, and the `scripts` folder. Sometimes you need to open one more folder with the same name, such as `windows-360-cleaner-main`.
3. Double-click **Start-Check** (full name `Start-Check.cmd`) or **开始检查** (`开始检查.cmd`). They are the same launcher with an English and a Chinese name.
4. The window opens and starts **checking the PC** automatically. Checking never deletes anything. The window title shows the version, for example `Windows 360 Cleaner v1.0.0`.

<p align="center">
  <img src="assets/screenshots/01-start-entry.png" alt="The extracted folder in File Explorer, with the 开始检查 file selected" width="400">
</p>
<p align="center"><sub>Example screenshot: the extracted folder; double-click 开始检查 or Start-Check. Unlike the other screenshots, this one is a real File Explorer file list without a banner, and nothing was checked or deleted when it was taken. It shows the contents of the versioned release ZIP. The ZIP from the link above has a few more folders (such as docs and tools) and no 使用说明 file; just find Start-Check.</sub></p>

> [!TIP]
> If the check result is hard to understand, that is fine: tick nothing and click **Close** (关闭). Nothing is deleted. If you want someone to help, click **Get help** (获取帮助).

## Window walkthrough: from checking to confirming it is all gone

Check the PC → read the "Delete?" answer of each row → tick items yourself → confirm → read the deletion result → restart yourself → check the last deletion.

> [!NOTE]
> The screenshots below show the **Chinese interface with sample data** (the yellow banner at the top of the window says it is a sample-data screenshot), and nothing real was checked or deleted when they were taken. The items on your PC will differ. On English Windows the window shows the English labels used below; the Chinese labels are added in parentheses so you can match them to the screenshots.

### 1. Wait for the check to finish

<p align="center">
  <img src="assets/screenshots/02-scan-progress.png" alt="Checking the PC: the current step (looking for 360 tasks that run on a timer), elapsed time 00:23 and the note that checking never deletes anything and can be stopped at any time, with a Stop checking button at the bottom" width="800">
</p>
<p align="center"><sub>Screenshot with sample data: checking the PC, showing only the current step and the elapsed time; the green bar only moves back and forth to show it is still working and is not a percentage.</sub></p>

- The window shows only the step it is on right now and the elapsed time. It does not show a made-up percentage.
- A check usually finishes in a minute or two. Please wait a moment.
- **Checking never deletes anything.** To stop, click **Stop checking** (停止检查). A stopped check did not finish, and its result cannot be used.

### 2. Read the check result: every row only answers "Delete?"

<p align="center">
  <img src="assets/screenshots/03-scan-results.png" alt="Check result saying 2 products have items you can delete: grouped by product with three columns Select, Item and Delete?; the 3 items of 360 Huabao / Duohui screen saver are ticked and show Will be deleted in red, 360 Secure Browser is not ticked and its personal data shows Won't delete: bookmarks and history; 360 temporary files and Not sure which 360 product show Won't delete: not sure it belongs to 360; the area below explains what deleting the Duohui installation folder does, and the bottom line says 3 items are selected for deletion" width="800">
</p>
<p align="center"><sub>Screenshot with sample data: for the demonstration, two products were expanded and the 3 items of "360 Huabao / Duohui screen saver" were ticked; when you open it for the first time, products are collapsed and nothing is ticked.</sub></p>

- The sentence at the top tells you how many 360 products have items you can delete. **Nothing is ticked when the window opens.**
- The list has only three columns: **Select** (勾选), **Item** (内容), and **Delete?** (删不删). Products are collapsed; click a product name to see each item inside it.
- The **Delete?** column has only two kinds of answers:
  - **Can be deleted** (可以删除): something 360 left behind that can be deleted. Whether to delete it is your decision (once ticked, it shows **Will be deleted** (要删除) in red).
  - **Won't delete: reason** (不删除：原因): for example "Won't delete: bookmarks and history", "Won't delete: system driver", "Won't delete: uninstall it normally first", or "Won't delete: not sure it belongs to 360". These rows cannot be ticked, and the tool never deletes them.
- Click any row, and the area below explains what it is and what happens if it is deleted. For the location, evidence, and other technical details, click **More info** (更多信息) next to it.
- If the yellow notice "Some places were not fully checked; the result may be incomplete." appears at the top, click **Show which ones** (看看是哪些) to see them. The items that are listed are correct, but something may have been missed.
- When nothing is found, the window says "No 360 content was found". When some places were not fully checked, it says "No 360 content was found, but some places were not fully checked". The two are different.

> [!IMPORTANT]
> **The window never decides for you.** "Can be deleted" only means the item is something 360 left behind that can be deleted. Whether to delete it, and which items, is decided only by what you tick.

### 3. Decide what to delete

- Tick only the items you are sure you do not want. **The tool does not delete unticked items.**
- Clicking the box in front of a product ticks the items of that product that **can be deleted and can safely be deleted together**; clicking it again unticks them all.
- **Select all deletable** (全选可以删除的) ticks only items that can be deleted. Rows that say "Won't delete" are never ticked. It only ever selects less for safety, never more.
- Some items could be deleted on their own, but no choice in this check result can delete them safely: for example a folder that contains things that must be kept, or an uninstaller that came with 360 whose folder cannot be deleted. Such rows say "Won't delete: it holds things that are kept" (不删除：里面有要保留的东西) or "Won't delete: it goes together with its folder" (不删除：要和它所在的文件夹一起删) and cannot be ticked, not even with a product row or **Select all deletable**.
- Occasionally a product row click does not tick an item for you (for example a folder that also contains unticked items of another product); one sentence below the list explains why.
- The bottom of the window shows `N item(s) selected for deletion.` (已选 N 项要删除。). At most 64 items can be deleted at a time.
- If you tick an **uninstaller that came with 360**, the sentence at the top turns orange: it may also remove parts of the same product that you did not tick.

Buttons at the bottom of the window:

| Button | What it does |
|---|---|
| **Delete selected...** (删除选中的内容…) | Available after you tick at least 1 item. It checks your selection first, then opens the "Delete these items?" dialog. Nothing is deleted yet |
| **Select all deletable** (全选可以删除的) | Ticks only items that can be deleted; for safety it may leave a few out, never add more |
| **Clear all** (全部不选) | Unticks everything |
| **Get help** (获取帮助) | Creates a text with personal information hidden as far as possible, so you can ask someone for help. See [Need help: Get help](#need-help-get-help) |
| **Close** (关闭) | Deletes nothing and closes the window |

After you click **Delete selected...**, if your selection needs to change, the "A few changes are needed" (还需要调整一下) dialog explains the problem and what to do. **At this point nothing has been deleted:**

- **More than 64 items are ticked**: untick some first (for example, delete one product at a time). After deleting, click **Check the PC again** (重新检查电脑) and delete the next batch.
- **You ticked a folder that still contains items you did not tick and that can be deleted on their own**: deleting the folder would delete them too. Click **Select these N too** (把这 N 项也选上), or do not delete the folder.
- **You ticked an uninstaller that came with 360 but not the folder it is in**: tick the folder too (click **Select these N too** when it is offered), or untick the uninstaller.

### 4. Confirm the deletion

<p align="center">
  <img src="assets/screenshots/04-confirm-delete.png" alt="The Delete these items? dialog: the 3 items to delete (Duohui installation folder, Duohui temporary installer files, the duohuipingbao startup entry), what happens after deleting each one, and what is kept: 360 Secure Browser (not selected), 360 temporary files and Not sure which 360 product; red text says deleted items cannot be recovered and do not go to the Recycle Bin; Cancel and a red Delete button at the bottom" width="640">
</p>
<p align="center"><sub>Screenshot with sample data: the "Delete these items?" dialog. The default button is Cancel.</sub></p>

Read each point carefully:

- **Deleted items cannot be recovered and do not go to the Recycle Bin.**
- **After deleting:** (删除后：) says what happens after each item is deleted; **Kept:** (会保留的：) lists what you did not select and what is not deleted.
- **The only exception**: if you ticked an uninstaller that came with 360, the dialog warns that it may also remove parts of the same product that you did not select. Those parts are then listed separately and are not described as kept.
- A browser's "program files" and its "personal data (bookmarks, history, ...)" are two different items. Personal data is not deleted and cannot be ticked in the window.
- Close the 360 programs first, and back up bookmarks or other data you need.
- The default button is **Cancel** (取消); pressing Enter or Esc only cancels. When you are sure, click the red **Delete** (删除) button. Windows then asks for permission; click "Yes".
- If you click "No" in the Windows permission window, the result page says "Nothing was deleted".

### 5. Wait for the deletion to finish and read the result

- Until Windows gives permission, the page title is "Click "Yes" when Windows asks for permission" (请在 Windows 弹出的窗口里点“是”); "Deleting..." (正在删除…) is shown only when deleting really starts.
- After permission is given, the tool checks once more that the items you ticked have not changed. If something changed, it stops before deleting anything.
- **Once deleting starts, it cannot be stopped**, and the window cannot be closed until it ends. Please wait, and do not shut down the PC.
- When it finishes, the result page gives a large headline saying whether the items were deleted, one sentence below it, the line `N deleted · N not deleted · N not sure` (删掉 N 项 · 没删掉 N 项 · 不确定 N 项; shown only when the result is certain), and what to do next. What each result means is explained in [What you see after a deletion](#what-you-see-after-a-deletion).

<p align="center">
  <img src="assets/screenshots/05-cleanup-result.png" alt="Deletion complete result page: a green headline Deletion complete, all 3 selected items were deleted and the tool did not touch anything you did not select, 3 deleted 0 not deleted 0 not sure, next step restart and click Check the last deletion; Close, Check the last deletion, Details and Get help buttons at the bottom" width="800">
</p>
<p align="center"><sub>Screenshot with sample data: deletion complete. The statistics and the record of every step are under Details.</sub></p>

### 6. Restart yourself, then open Start-Check again

- **The tool never restarts your PC.** Save the documents you are working on, then restart yourself.
- After restarting, double-click `Start-Check` again. When the tool finds the record of your last deletion, the home page shows **Last deletion** (上次删除的记录): the time, how many items were selected for deletion and how many were kept, and whether the PC has restarted since then.

<p align="center">
  <img src="assets/screenshots/06-home-after-restart.png" alt="Home page after reopening: Last deletion, the time, 3 items selected for deletion and 1 kept, the PC has restarted so the result can be checked, and checking never deletes anything; Check the last deletion, Check the PC again and Close buttons at the bottom" width="800">
</p>
<p align="center"><sub>Screenshot with sample data: reopened after a restart, the home page found the record of the last deletion.</sub></p>

| Button | What it does |
|---|---|
| **Check the last deletion** (检查上次删除的结果) | Checks item by item whether the items selected last time are gone (recommended). Checking never deletes anything |
| **Check the PC again** (重新检查电脑) | Checks the PC again to see what is on it now |
| **Close** (关闭) | Closes the window |

- If the home page says the PC has not restarted yet, save your work and restart the PC yourself before checking the result.
- **Check the last deletion** on the deletion result page also checks right away. However, some items can only be deleted completely after a restart, so a check before restarting may still show them.

### 7. Check the last deletion

<p align="center">
  <img src="assets/screenshots/07-verify-result.png" alt="Check the last deletion: a green headline Everything selected last time is gone, all 3 items selected last time are confirmed gone and the items you kept are still there; Kept by you (1): 360 Secure Browser program files, still there; Deleted (3); Next: you can close the tool now; Close, Check the PC again and Get help buttons" width="800">
</p>
<p align="center"><sub>Screenshot with sample data: the 3 Duohui screen saver items are deleted; "360 Secure Browser program files" was kept by you and is still there, which is normal and does not count as a failed deletion.</sub></p>

- Checking **never deletes anything**.
- Items you kept are shown under **Kept by you** (你保留的) with the state "Still there" (还在), and do not make the deletion count as failed.
- If an item you kept is gone (for example, removed together by an uninstaller that came with 360), it is shown separately under **Kept by you, but gone** (你保留的，但不见了), and the headline is not green.
- Only items that a direct check confirmed as no longer present count as **Deleted** (已删掉).
- If new 360 items are found and you want to handle them, click **Check the PC again**, look at the result again, and decide again.
- What each headline means is explained in [How to read the check of the last deletion](#how-to-read-the-check-of-the-last-deletion).

## How to read the "Delete?" column

The **Delete?** (删不删) column of the check result has only two kinds of answers. **Only "Can be deleted" can be ticked.** An agent uses the same words in a conversation.

| Shown | What it means | Can it be ticked? |
|---|---|---|
| **Can be deleted** (可以删除) | Something 360 left behind that can be deleted. The window does not decide for you; an agent may suggest deleting it, but the decision is still yours | Yes, if you decide to |
| **Won't delete: not sure it belongs to 360** (不删除：不能确定是 360 的) | The name or location looks like 360, but it is not certain that it really belongs to 360. To avoid deleting the wrong thing, it is not deleted | No |
| **Won't delete: bookmarks and history** (不删除：书签和历史记录) | Browser bookmarks, history, saved passwords, and other personal data | No |
| **Won't delete: in another Windows installation** (不删除：在另一个 Windows 系统里) | Found in another Windows installation on this PC (for example, on another disk) | No |
| **Won't delete: system driver** (不删除：系统驱动) | Deleting a system driver directly can cause blue screens or stop Windows from starting | No |
| **Won't delete: this is other software** (不删除：这是别的软件) | Software from another company that contains some 360 parts. The whole program is never deleted; the separate 360 parts inside it are listed as their own items | Not as a whole |
| **Won't delete: details incomplete** (不删除：信息不完整) | The details of this item could not be confirmed, so it is not deleted to avoid deleting the wrong thing | No; you can check the PC again later |
| **Won't delete: uninstall it normally first** (不删除：请先正常卸载) | This program still looks installed. Uninstall it in Windows Settings → Apps first, then check the PC again | No |
| **Won't delete: it holds things that are kept** (不删除：里面有要保留的东西) | It could be deleted on its own, but it contains things the tool does not delete, and deleting it would delete those too | No |
| **Won't delete: it goes together with its folder** (不删除：要和它所在的文件夹一起删) | An uninstaller that came with 360 can only be deleted together with its folder, and that folder cannot be deleted | No |
| **Won't delete: please check again** (不删除：请重新检查) | This result comes from an older version of the tool | No; check the PC again |

## What you see after a deletion

The result page gives one large headline, one sentence below it, and what to do next. Failed, uncertain, and restart-needed results **never look like success, in headline or colour**. An agent tells you the same headlines in a conversation, except "Nothing was deleted": the agent cannot confirm that you clicked "No" in the Windows permission window, so it says "Not sure everything was deleted" instead.

| Result page headline | What it means | Next step |
|---|---|---|
| **Deletion complete** (删除完成, green) | Everything you selected was deleted, and the check right after deleting confirmed it. The tool did not touch what you did not select | You can close the tool; when convenient, save your work, restart yourself, then click **Check the last deletion** |
| **Deletion complete** (删除完成, orange) | Everything you selected was deleted, but an uninstaller that came with 360 ran, or some items you did not select could not be confirmed as still present afterwards; the page says which | As above; if you still need the items you did not select, check them after the restart |
| **One more step: restart the PC** (还差一步：请重启电脑) | Some items are in use, or a background service is waiting for a restart, so the deletion can only finish after a restart | Save your work, restart yourself, then click **Check the last deletion** |
| **Some items were not deleted** (有些没删掉) | Some items were not deleted; the reasons are listed below (items with the same reason are merged into one line). Or the deletion program did not end normally | Restart the PC first, then click **Check the last deletion**; if it still does not work, click **Get help** |
| **Not sure everything was deleted** (不确定有没有删干净) | No trustworthy deletion result was received, or the check after deleting could not run | Do not treat it as done; restart and check again |
| **Nothing was deleted** (没有删除任何东西) | For example, you clicked "No" in the Windows permission window | You can check the PC again, or just close |

- The line `N deleted · N not deleted · N not sure` is shown only under "Deletion complete" and "Some items were not deleted", never under the uncertain or restart-needed results.
- The **Details** (详细信息) window has the statistics (deleted files, folders, background services, timer tasks, settings left by 360, and so on), every item that was not deleted or not finished, the record of every step, and **Open the records folder** (打开记录所在文件夹).
- **Logical file size** is not the same as the free disk space actually gained. When some places could not be measured, the numbers are minimum values.

## How to read the check of the last deletion

Checking **never deletes anything**. The list shows only the groups that have items, in this order:

| Group | What it contains |
|---|---|
| **Not deleted** (没删掉) | Items selected last time that are still there |
| **Could not be confirmed or not fully checked** (没法确认或没检查完) | Items that could not be read or confirmed, and places that were not fully checked |
| **Newly found or changed** (新找到的或有变化的) | 360 items found for the first time, and items that are different from last time |
| **Kept by you, but gone** (你保留的，但不见了) | Items not selected last time that are gone now (for example, removed together by an uninstaller that came with 360). Reinstall them if you still need them |
| **Kept by you** (你保留的) | Items not selected last time that are still there. **This is normal and does not count as a failed deletion** |
| **Deleted** (已删掉) | Items selected last time that a direct check confirmed are no longer present |

After you click **Check the last deletion**, the headline at the top of the page is one of:

| Headline | What it means | Next step |
|---|---|---|
| **Everything selected last time is gone** (上次选的都删干净了) | Everything selected last time was confirmed as deleted (the headline is orange when an item you kept is gone, and the sentence below says so) | You can close the tool |
| **Everything selected last time is gone, but some places were not fully checked** (上次选的都删干净了，但有些地方没检查完) | Deleted, but some places were not fully checked this time | Check once more later |
| **Everything selected last time is gone, but N new 360 item(s) were found** (上次选的都删干净了，但又找到 N 项新的 360 内容) | Everything selected last time was deleted, but new items were found this time | Click **Check the PC again**, then decide whether to delete them |
| **N item(s) were not deleted** (还有 N 项没删掉) | Some of the items selected last time are still there or have changed | Restart the PC, open the tool and check again; if they still cannot be deleted, click **Get help** |
| **N item(s) could not be confirmed as deleted** (有 N 项没法确认有没有删掉) / **Everything selected last time looks gone, but this check was not complete** (上次选的看起来都删掉了，但这次检查没做完整) | The check could not confirm the result, so it must not be treated as all gone | Restart the PC, open the tool and check again; if it still does not work, click **Get help** |
| **The record of the last deletion cannot be used, so the whole PC was checked again** (上次删除的记录用不了，已经重新检查了一遍电脑) | For example, the last record cannot be found or read, has an incompatible version, or the deletion was done by another Windows user, so items cannot be checked one by one; the page shows the result of checking the PC again | Click **Check the PC again** to see what is there now |

When there is no record of a last deletion and the whole PC is checked directly (for example with `scripts\Verify-360.cmd`), the headline is **No 360 content that needs attention was found** (没有找到还需要处理的 360 内容), **N 360 item(s) are still on this PC** (电脑上还有 N 项 360 的内容), **No 360 content that needs attention was found, but some places were not fully checked** (没有找到还需要处理的 360 内容，但有些地方没检查完), or **Nothing that can be deleted was found, but N 360 item(s) that are not deleted remain** (没有找到可以删除的 360 内容，但还有 N 项不删除的内容; for example a program that is still installed and must be uninstalled normally first). The list is then split into **360 items still on this PC** (现在还有的 360 内容), **Could not be confirmed or not fully checked** (没法确认或没检查完), and **Won't be deleted** (不删除的). They are not labelled as new.

Checking does not need Windows permission. If the check and deletion ran as administrator, timer tasks, background services, or programs that a normal account cannot see are listed under "Could not be confirmed or not fully checked", never as deleted.

## Need help: Get help

The check result page, the deletion result page, the page that checks the last deletion, and error pages all have a **Get help** (获取帮助) button.

- It **creates a separate text with the problem information on your PC**, hiding user names, computer names, SIDs, e-mail addresses, private paths, and similar information as far as possible, but something may be missed.
- The text in the preview box can be edited. **Check every line before sending it to anyone**, and make sure it contains no names, accounts, private folders, or similar information.
- Buttons: **Copy** (复制), **Save as a file** (保存成文件; named like `360-cleanup-help-….txt`, in the same folder as the records), **Open the help web page** (打开求助网页), **Open the records folder** (打开记录所在文件夹), and **Close** (关闭).
- **Open the help web page** only opens a fixed help page in your browser; it sends nothing automatically. Submitting a help request on GitHub requires signing in to a GitHub account.
- The original records stay unchanged. The problem information is only for discussion and **cannot be used to delete anything**. The tool never uploads anything.

You can also [open the help page](https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml) directly and paste in the text you checked. Do not upload the original record files. If you use an agent, you can also ask it first to explain in plain words what went wrong.

## What this tool never does

- **It never chooses for you.** The window opens with nothing ticked, and "Select all deletable" ticks items only when you click it yourself; an agent may suggest, but deletes only the numbers you name yourself. Rows that say "Won't delete" can never be selected.
- **It never deletes without your confirmation.** In the window you tick items yourself, read the "Delete these items?" dialog and click "Delete"; in a conversation you read the confirmation text and reply "yes, delete". After that Windows still asks for permission.
- **It never deletes by "the name contains 360".** It only handles items whose location matches exactly and whose 360 program really is on this PC.
- Rows that say "Won't delete" (for example not sure it belongs to 360, in another Windows installation, or bookmarks and history) **cannot be deleted here**.
- Browser bookmarks, history, and other personal data are **not deleted** and are listed separately from browser program files.
- Not deleted, uncertain, and restart-needed results are **never presented as success**.
- **It never restarts your PC, never runs at startup, never stays in the background, and never uploads anything.**
- Checking the PC and checking the last deletion **only read information** and never delete anything.

> [!WARNING]
> Do not "search for every file whose name contains `360` and force-delete them". The number 360 can appear in photos, game maps, models, hashes, and Windows files.

What it does not delete by default:

- Files or folders whose only link to 360 is the number `360` in their name.
- Built-in Windows screen savers such as `Bubbles.scr`, `PhotoScreensaver.scr`, and `scrnsave.scr`.
- Driver Genius (驱动精灵), GPU and network drivers, game folders, and numeric Steam/iRacing assets.
- The independent image viewer, cleaner, PDF, and zip tools inside `winToolBox` (`kantu`, `clear`, `pdf`, `zip`).
- 360 browser personal data (bookmarks, history, sessions, and so on).
- Any file in another Windows installation.

## FAQ

<details>
<summary><strong>Should I use an agent or the Start-Check window?</strong></summary>

If your agent can run PowerShell on this PC (for example Codex), just tell it "check this PC for 360 software", and it tells you in plain words what can be deleted. If your agent cannot reach your PC (for example Doubao on the web), or you do not use an agent, download and extract the ZIP and double-click `Start-Check`. Both say the same things, checking never deletes anything, and every deletion needs your own confirmation.

</details>

<details>
<summary><strong>The agent says "I suggest deleting it". Do I have to?</strong></summary>

No. A suggestion is only a suggestion: only the numbers you name are deleted, and anything you do not name is kept. Do not delete software you still use; if you are unsure, keep it for now. The agent never suggests deleting anything marked "won't delete".

</details>

<details>
<summary><strong>The agent says it is done, but I am not sure it really checked anything?</strong></summary>

Some chatbots only write out commands and never actually run them on your PC. If it did not show you a check result, and did not show you a confirmation text before deleting, do not treat anything as checked or deleted. You can use the `Start-Check` window instead.

</details>

<details>
<summary><strong>Double-clicking Start-Check does nothing, or says the program files in the scripts folder were not found?</strong></summary>

Most likely the ZIP was not fully extracted. Right-click the ZIP, choose **Extract All**, and then double-click `Start-Check` in the extracted folder. Do not copy out only `Start-Check.cmd`, and do not run it from inside the ZIP.

If it says "The tool is already open." (本工具已经打开了。), the window is already open; find it in the taskbar.

If a message says Windows PowerShell could not run the cleaner, it may be blocked by a system policy or security software, or files may be damaged. Do not turn off your security protection to run this tool; run `scripts\Scan-360.cmd` to see the error, or take a screenshot of the message and ask for help. On a work or school PC, ask the administrator. If something was being deleted when the message appeared, it is not certain that everything was deleted: restart the PC, double-click `Start-Check` again and click **Check the last deletion** (检查上次删除的结果).

</details>

<details>
<summary><strong>Windows says "The publisher could not be verified", or will not let it run?</strong></summary>

This happens because the scripts are not digitally signed. First make sure the ZIP was downloaded from this page (`github.com/LongXL6/windows-360-cleaner`); if you are not sure, do not run it.

If a company or school PC blocks it by policy, contact the PC's administrator. **Do not turn off antivirus software or Windows security protection to run it.**

</details>

<details>
<summary><strong>Should every item that says "Can be deleted" be deleted?</strong></summary>

Not necessarily. "Can be deleted" only means the item is something 360 left behind that can be deleted. If you still use it (for example 360 Secure Browser), keep it for now; if you are unsure, do not tick it or name its number. The tool does not delete what you did not choose.

</details>

<details>
<summary><strong>Will it delete my browser bookmarks?</strong></summary>

Not by default. A browser's "personal data (bookmarks, history, ...)" and its "program files" are two different items. Personal data is shown as "Won't delete: bookmarks and history", cannot be ticked in the window, and is never included by an agent. After browser program files are deleted, the browser no longer opens, so it is still a good idea to back up the bookmarks you need before deleting.

</details>

<details>
<summary><strong>I clicked "No" when Windows asked for permission, or I want to stop in the middle of a deletion?</strong></summary>

If you click "No" when Windows asks for permission, nothing is deleted, and the window's result page says "Nothing was deleted".

Once deleting starts, it cannot be stopped and the window cannot be closed, so that you never end up half-way with no clear idea of what was deleted. A check can be stopped at any time with "Stop checking", and stopping deletes nothing.

</details>

<details>
<summary><strong>After deleting it says "One more step: restart the PC", "Some items were not deleted", or "Not sure everything was deleted"?</strong></summary>

Some files are in use and can only be deleted completely after a restart; this is common. Save your work, restart yourself, double-click `Start-Check` again, and click **Check the last deletion**. If you deleted with an agent, tell the agent "it has restarted" after the restart.

Do not keep forcing deletion. If there are still problems when you check after the restart, click **Get help**, check the text, and send it to someone willing to help, or submit it on the GitHub help page.

</details>

<details>
<summary><strong>After restarting, "Last deletion" did not appear and a check of the PC started right away?</strong></summary>

The tool did not find a usable record of the last deletion. For example, the record file on the Desktop was moved or deleted, the last deletion never really started, or the last deletion used a version before 1.0.0. If the last deletion was made in an agent conversation, the window's home page does not show it either; go back to the agent and say "check the last deletion". The window simply checks the PC again, which still shows you what is on the PC now.

</details>

<details>
<summary><strong>Where are the record files saved? Do I need to open them?</strong></summary>

You do not need to open them; the window and the agent explain their content in plain words. Record files are saved on the Desktop (in the temporary folder if the Desktop is unavailable), with names like:

- `360-cleanup-scan-….json`: record of checking the PC
- `360-cleanup-remove-….json`: record of the deletion
- `360-cleanup-verify-….json`: record of checking the last deletion
- `360-cleanup-task-….json`: task record left by a deletion in the window, used only to find the matching record when you check the last deletion after a restart. **It can never be used to delete anything**

Click **Open the records folder** in the Details or Get help window to find them directly. Records can contain file paths on your PC, so do not share them publicly; when asking for help, use the text from Get help after checking it.

</details>

<details>
<summary><strong>Can I only delete 64 items at a time?</strong></summary>

Yes. This limit exists for safety. Delete one part first (for example, one product at a time), check the PC again afterwards, and then delete the next batch. In a conversation, if one product alone has more than 64 items, the agent asks you to use the `Start-Check` window and delete it in several rounds.

</details>

<details>
<summary><strong>360 or the Duohui screen saver came back after being deleted?</strong></summary>

An update service or timer task that downloads it may still be there. Check the PC again (ask your agent, or double-click `Start-Check` again), and look for related background services, tasks that run on a timer, or 360 program files inside winToolBox. The background is explained in "Why does the Duohui screen saver come back after being deleted?" under [Detection scope (technical details)](#detection-scope-technical-details), and how to approach it in [troubleshooting](references/troubleshooting.md).

</details>

<details>
<summary><strong>Can I use it on a phone or a Mac?</strong></summary>

No. It only runs on Windows 10/11 PCs. A phone can display the instructions, but you need to use it on the Windows PC you want to check.

</details>

For more step-by-step help with screenshots and common sticking points, see the [beginner guide](references/getting-started.en.md).

---

## For maintainers: technical details

The content below is for maintainers, developers, and users who want the details. Ordinary users do not need to read it or run any command.

### Advanced command line

The core script is `scripts\Invoke-360Cleanup.ps1`. Running it directly does not open the window; it only writes a JSON report, which suits agents, CI, and report-only use. The plain-words translator for agents is `scripts\Show-360Summary.ps1`: it only reads reports and prints text, and never deletes anything, starts a process, writes a file, or uploads anything.

<details>
<summary><strong>PowerShell commands and advanced options</strong></summary>

```powershell
# Read-only scan (no window)
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan

# Turn the scan report into plain words (for agents; the trailing AGENT: lines are never read to the user)
.\scripts\Show-360Summary.ps1 -Report 'C:\path\to\scan-report.json' -Language en

# After the user names numbers: print the confirmation text and the exact Remove command (deletes nothing; use the report-sha256 printed by the previous step)
.\scripts\Show-360Summary.ps1 -Report 'C:\path\to\scan-report.json' -Language en -ScanReportHash <report-sha256> -Delete 1,2

# After removal and after verification: always pass the exit code of that command (unknown when it was lost)
.\scripts\Show-360Summary.ps1 -Report 'C:\path\to\remove-report.json' -Mode Remove -Language en -ScanReportHash <report-sha256> -ExitCode 0
.\scripts\Show-360Summary.ps1 -Report 'C:\path\to\verify-report.json' -Mode Verify -Language en -ExitCode 0

# In a new conversation: find the newest deletion of this Windows user (read-only)
.\scripts\Show-360Summary.ps1 -FindLastRemove -Language en

# Clean by a whole reviewed Scan report: needs administrator permission (UAC), a switch, and the exact confirmation phrase
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ApprovedReport 'C:\path\to\approved-scan.json' `
  -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360

# After a restart: read-only verification of this cleanup (compares against the selection recorded in the Remove report)
.\scripts\Invoke-360Cleanup.ps1 -Mode Verify -PreviousRemoveReport 'C:\path\to\remove-report.json'

# Read-only check of the whole PC without a cleanup record
.\scripts\Invoke-360Cleanup.ps1 -Mode Verify

# High-risk option: first create a Scan report with the same option, back up, and review browser data separately
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -IncludeBrowserProfiles

# Then remove with the report that the previous step actually created and that you reviewed
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ApprovedReport 'C:\path\to\approved-scan.json' `
  -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 `
  -IncludeBrowserProfiles -BrowserProfileConfirmation DELETE-360-BROWSER-DATA

# Scan Windows on another disk; it is never cleaned
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -OfflineWindowsRoot F:\
```

- Without a selection parameter, Remove processes the whole intersection of the approved report and the post-elevation rescan that is still `Confirmed`. To handle only some items, tick them in the window, or in a conversation let `Show-360Summary.ps1 -Delete` build the command from the numbers the user named; both bind the selected IDs to the SHA-256 of the original Scan report. Do not construct or widen a selection list by hand.
- `Show-360Summary.ps1` exit codes: `0` summary printed (with `-Delete`: the choice passed its checks and the Remove command is included); `2` no conclusion (missing or invalid `-ExitCode` or `-ScanReportHash`; the report is missing or unreadable and its step cannot be told, because there is no `-Mode` and the file name is not `360-cleanup-scan|remove|verify-*`; the report is of the wrong kind; or a value was given without its parameter name). A missing report whose step is known still gives `0` with text that never says finished (for Remove: "Not sure everything was deleted"); `3` the `-Delete` choice was not accepted and no Remove command is printed; `1` unexpected error. Parameters, `AGENT:` lines, and `-Json` fields are documented in [SKILL.md](SKILL.md).
- `-EmitProgress` and `-ElevatedProgressPath` only let the window show the current phase; they do not change what is removed.
- `-AllowExplorerRestart` and `-ForceLockedTargets` are advanced troubleshooting options and are not used in the beginner flow. An agent must first explain the exact target and risk and then get a fresh approval. For an `AccessDenied` path, `-ForceLockedTargets` repairs the ACL of the exact verified path only after all other actions, then rescans from the approved root; as soon as a reparse point or an unknown inspection error appears, nothing is deleted.

**Verify exit codes:**

| Case | `0` | `2` | `3` | `4` |
|---|---|---|---|---|
| Without `-PreviousRemoveReport` | No `Confirmed` findings and complete checks | `Confirmed` findings remain | No `Confirmed` findings, but checks incomplete | — |
| With `-PreviousRemoveReport` | Selected targets all gone, no new findings, complete checks | Selected targets still present or changed; or the record is unavailable and `Confirmed` findings remain | Selected targets unknown, checks incomplete, or the record is unavailable with no `Confirmed` findings | Selected targets gone, but new `Confirmed` findings appeared |

Targets the user chose to keep never cause a failure. The full rules are in [SKILL.md](SKILL.md).

**Other entry points:**

- `scripts\Scan-360.cmd` and `scripts\Verify-360.cmd`: open the same window and go straight to "Check the PC" or "Check the last deletion" (checking the last deletion item by item when its record is found, otherwise checking the whole PC), keeping a console window open.
- `scripts\Remove-360.cmd`: the legacy/advanced "whole report" command-line route. Press `Y`, type `REMOVE-360`, drag in the reviewed Scan JSON, and then confirm in the Windows permission prompt. It processes every target in that report that is still confirmed, so it does not suit beginners who want to delete only a few items.

</details>

### Result reporting

<p align="center">
  <img src="assets/readme/cleanup-report.svg" alt="Illustration of the Remove report Summary statistics and the content kept by default; the numbers are only for demonstration" width="100%">
</p>

- The window saves reports on the Desktop (in the temporary folder if the Desktop is unavailable), named `360-cleanup-scan-*.json`, `360-cleanup-remove-*.json`, and `360-cleanup-verify-*.json`, plus the `360-cleanup-task-*.json` task record and any `360-cleanup-help-*.txt` problem information the user saves from Get help. When the core script runs directly without `-ReportPath`, the default name is `360-cleanup-report-*.json`; the commands printed by `Show-360Summary.ps1` carry new paths such as `360-cleanup-remove-*.json` and `360-cleanup-verify-*.json`.
- Reports are only ever created as new files; the script refuses to overwrite an existing file or use another extension.
- Reports remain `SchemaVersion 2`. The fields added in 1.0.0 (`ToolVersion`, `ScanCoverage`, `ProductKey` on every finding, `Selection` in Remove reports, `TaskVerification` in Verify reports) are all optional, and older reports remain readable. A Remove report from an older version has no recorded selection, so checking the last deletion item by item is shown as unavailable (`SelectionNotRecorded`), while Verify without `-PreviousRemoveReport` (checking the whole PC) still works.
- `ProductKey` and the numbers printed by `Show-360Summary.ps1` are only used for grouping the display; they never widen or narrow an approval.

The `Summary` in a Remove report records:

- Total objects, files, directories, and logical file size removed.
- Services removed, and services still waiting for a Windows restart to be removed.
- Scheduled tasks, registry keys, and registry values removed.
- Target processes stopped, and the numbers of skipped, failed, pending, retried, and finally unresolved actions.
- Access-denied paths, ACL repair attempts and failures, and paths still unresolved.
- Vendor uninstaller successes, failures, and pending runs, and whether the safety check after the vendor uninstaller blocked later actions.
- The approved count, the intersection that can still be processed, and how many findings appeared, disappeared, or stopped being confirmed since approval.
- Targets ticked in this run, unticked targets explicitly kept, and selected targets that the immediate check confirmed gone, found still present, or could not confirm.
- Paths fully removed, partially cleaned, and not safely measurable.

File sizes come from the difference between safe snapshots before and after deletion, with parent and child targets deduplicated. Hard links, sparse files, and compressed files can make the "logical file size" differ from the free disk space actually gained, so this project never treats the two as the same. If `ImmediateRescanComplete` is false, the Findings in the report are only the last safe snapshot taken before any change, not proof of what remains, and the run must be marked as needing attention. The final result after a restart is the Verify report's `TaskVerification` and `Findings`. By default an agent reports the result in a few plain sentences (Required final output in [SKILL.md](SKILL.md)); the full list of fields to report when the user asks for details is under Details on request there.

### Safety design details

| Safeguard | Actual behavior |
|---|---|
| Scan before delete | `Scan` is read-only; `Remove` needs an unmodified Scan report, a switch, the exact confirmation phrase, and Windows administrator permission (UAC) |
| Never chooses for the user | The window opens with nothing ticked; an agent may give a "suggest deleting / won't delete" recommendation, but uses only the numbers the user names. Only online, removable `Confirmed` items can be selected, and everything not selected is kept |
| "Select all deletable" only shrinks | The product row, "Select all deletable", and `Show-360Summary.ps1 -Delete` all use the same library function: it takes only deletable items, drops a folder that would take kept content with it and a vendor uninstaller whose install folder is not selectable, never adds an item outside the candidates, and never silently truncates to 64 items. The largest set of items that can safely be deleted together is worked out once for the whole check result; an item outside it can never pass the check, so it is shown as "Won't delete: reason", cannot be ticked, and is not counted as deletable. This layer only ever offers less, never more, and the core approval checks are unchanged |
| Confirmation before deleting | The window's confirmation dialog defaults to "Cancel"; in a conversation the agent must show the same confirmation text, wait for the user's explicit "yes, delete", and then run the printed command unchanged |
| Re-checked after elevation | Selected IDs are bound to the SHA-256 of the original Scan report. After elevation the tool rescans, and stops before deleting if a selected target changed, disappeared, or was downgraded, or if a selected parent folder would take unselected or won't-delete content with it |
| Per-run limit | The window and `Show-360Summary.ps1 -Delete` submit at most 64 items at a time |
| Insufficient evidence is never forced | Suspicious targets become `ReviewOnly` (shown as "Won't delete: reason") and are never automatically upgraded to removable |
| Broad paths rejected | Drive roots, Windows, user profile folders, a whole Temp folder, and similar paths can never become removal targets |
| No directory escape | A junction or symbolic link in a target, its parent chain, or its subtree makes it fail closed |
| Access denied is not success | By default only the exact path that cannot be fully inspected is skipped; other approved targets continue, and the result is marked as needing attention |
| Browser data protected separately | Bookmarks, history, and sessions are kept by default; they cannot be ticked in the window, `Show-360Summary.ps1 -Delete` leaves them out by default, and deleting them from the command line needs a separate switch and confirmation phrase |
| Vendor uninstaller restricted | Only the Duohui uninstaller whose signature, hash, path, and product evidence all pass a fresh check is run, and only with its built-in argument; the confirmation text says it may remove unselected parts of the same product |
| Normal software is not killed | An ordinary application that merely loaded a target DLL is not force-stopped; the default is to restart and verify |
| No cross-system deletion | Offline Windows on another disk is always scan-only |
| Verification is always read-only | A previous Remove report, a task record, or help text is only used for comparison and never counts as approval to delete |
| Results never pose as success | Not deleted, not sure, and restart-needed are never shown as success; `Show-360Summary.ps1` gives no conclusion without an exit code, and a missing Remove report is "not sure", never "nothing was deleted" |
| Reports never overwrite files | JSON reports can only be created as new files; overwriting an existing report or disguising another extension is refused, so running the same removal command twice stops before changing anything |
| Separate identity fields omitted | `ComputerName` / `User` are empty by default; paths and approval context can still contain personal information |

### Detection scope (technical details)

- Installation folders and uninstall records of 360 Total Security, 360 Antivirus, 360 browsers, 360 Speed Browser, 360 Software Manager, and similar products.
- Huabao / screen saver components such as `dhpingbao`, `duohuipingbao`, `huabao_tmp`, and `360hb_tmp`.
- `SoftMgrUpdate*` scheduled tasks and evidence-backed third-party toolbox download chains.
- Startup entries, services, and running processes that point to confirmed targets.
- Locking modules loaded by Explorer, such as `qcnethelp64.dll`, `xhqcnethelp64.dll`, and `SoftMgrExt64.dll`.
- Other Windows disks the user specifies; these results are always report-only and never cleaned across systems.
- Browser personal data in `360se6\User Data`, `360Chrome\Chrome\User Data`, `360ChromeX\Chrome\User Data`, and the legacy `360browser` path is kept by default; program folders are detected separately.

The detection evidence and known false positives are in the [detection catalog](references/detection-catalog.md).

<details>
<summary><strong>Who makes WinToolBox, and why does it appear with 360 components?</strong></summary>

`WinToolBox` is not Microsoft or official Windows software, and it is not an official 360 product. On a real machine we confirmed that its main program, image viewer, cleaner, and PDF components are signed by **Beijing Aolande Information Technology Co., Ltd.** (北京奥蓝德信息科技有限公司); its service name contains `huajun`, consistent with the Huajun software download site family (华军软件园).

The same toolbox folder can also contain `KitTip.dll` and `cssdk.dll` signed by **Beijing Qihu Technology Co., Ltd.** (北京奇虎科技有限公司); the latter's product information reads `360.cn / 统计组件` (statistics component). We have also seen its `SoftMgr` subfolder contain 360 Total Security components and take part in downloading the Duohui screen saver.

This project therefore describes it as **an Aolande/Huajun-family third-party toolbox. When the PC has Qihoo-signed DLLs, 360 SoftMgr, automatic download tasks, or the Duohui screen saver chain, it is treated as a PUP/bundleware carrier, and never mislabeled as an official 360 WinToolBox.** In the window and in agent summaries, the whole toolbox is shown as "Won't delete: this is other software", and only its separately identified 360 parts show "Can be deleted".

A digital signature only proves the publisher's identity; it does not mean the software behaves the way the user wants. Public sites: [Aolande](https://www.softbutler.cn/) · [Huajun software site](https://www.onlinedown.net/contact.html)

</details>

<details>
<summary><strong>Why does the Duohui screen saver come back after being deleted?</strong></summary>

One real chain we observed was:

```text
Aolande/Huajun winToolBox update service
  -> SoftMgrUpdate* scheduled task containing 360 components
  -> Temp\duohuipingbao\360hb_tmp\huabaosetup.exe
  -> AppData\Local\dhpingbao\duohuipingbao.exe
  -> Explorer loads qcnethelp / SoftMgrExt DLLs
```

If only the final screen saver folder is deleted while the evidence-backed download service and update task remain, it can come back. This skill looks for the download source first, then handles persistence, and verifies last; an ordinary application that merely loaded a target DLL is not force-stopped.

When the confirmed `%LOCALAPPDATA%\dhpingbao` contains an evidence-matching `huabaosetup.exe`, Scan lists its exact path and SHA-256 as a separate approval item (shown in the window as "Uninstaller that came with the Duohui screen saver"). Because it is an executable in a user-writable folder, it must also have a valid Authenticode signature whose signer simple name is exactly `Beijing Qihu Technology Co., Ltd.`; otherwise it is only marked `ReviewOnly`. Remove checks the signature, hash, and path again before launching it and uses only the built-in `/uninstall:byUserName` argument; it never blindly runs a command line from the registry. The stable identity fingerprints of services, tasks, and registry objects are also part of the Scan approval; any same-name replacement or later change is skipped and requires a fresh scan and approval.

</details>

### Validate the skill package

```powershell
.\scripts\Test-360Cleaner.ps1
```

It:

- Checks PowerShell 5.1 encoding (UTF-8 BOM) and syntax.
- Runs one read-only Scan of this PC and checks the report structure.
- Tests the deletion safety logic on isolated fixtures in the system temporary folder: report overwrite protection, double confirmation and cancellation exit codes, ordinary `360`-named user files and browser bookmarks staying untouched, and forged markers, junctions, locked files, and offline Windows failing closed. The tests never run Remove against real 360 software on this PC.
- Runs the detection, elevation, approval, path safety, vendor uninstaller, verification, UI text library, UI contract, UI layout, and agent plain-summary (`Show-360Summary.ps1`) tests under `tests\`.
- Also runs the packaging tests when `tools\Build-Release.ps1` exists in the repository (the versioned ZIP has no `tools` folder, so they are skipped there automatically).

GitHub Actions runs the same suite on every push and pull request.

### Build a versioned ZIP

Maintainers run `tools\Build-Release.ps1`, which creates `windows-360-cleaner-v<version>.zip` and a matching `.sha256` checksum file in `dist\`. The script first checks that `VERSION`, the core script, the UI library, and `CHANGELOG.md` carry the same version; it only creates those two files in the output folder and **never publishes, uploads, tags, or commits**.

The ZIP contains one `windows-360-cleaner-v<version>` folder with the two Start-Check launchers, `使用说明.txt` (rendered from the `packaging\使用说明.txt` template), the READMEs, `SKILL.md`, `CHANGELOG.md`, `VERSION`, `LICENSE`, `agents`, `scripts` (including `Show-360Summary.ps1`), `tests`, `references`, `assets\readme`, and `assets\screenshots`. It excludes `.github`, `docs`, `tools`, `packaging`, and scan reports.

The complete steps for updating the version, running the tests, inspecting the ZIP, and creating a GitHub Release manually are in the "发布版本 ZIP" (release ZIP) section of the [publishing and maintenance guide](references/publishing.md).

### Package structure

```text
windows-360-cleaner/
├── 开始检查.cmd                  # Launcher when no agent can run commands: double-click to open the window
├── Start-Check.cmd               # English-named launcher, identical to 开始检查.cmd
├── VERSION                       # Current version number
├── CHANGELOG.md                  # Changelog
├── SKILL.md                      # Agent entry point, safety rules, and how to talk to the user
├── agents/openai.yaml            # Codex display metadata and default prompt
├── scripts/
│   ├── Invoke-360Cleanup.ps1     # Core: Scan / Remove / Verify
│   ├── Show-360Summary.ps1       # For agents: plain-words summary, confirmation text and exact commands (read-only)
│   ├── Select-360Cleanup.ps1     # Window: check, tick, confirm, result, check the last deletion
│   ├── Windows360Cleaner.Library.ps1  # Texts, grouping, selection checks, outcomes, task records, and help text shared by the window and the agent summary
│   ├── Scan-360.cmd              # Goes straight to the check, with a console window
│   ├── Verify-360.cmd            # Goes straight to checking the last deletion, with a console window
│   ├── Remove-360.cmd            # Advanced: whole-report command-line cleanup
│   └── Test-360Cleaner.ps1       # Test suite entry point
├── tests/                        # Isolated tests for each module
├── references/                   # Beginner guides, Doubao guide, detection evidence, troubleshooting, sharing copy, publishing
├── docs/                         # GitHub Pages site in Chinese and English
├── tools/                        # Build-Release.ps1 (versioned ZIP), New-UiScreenshots.ps1 (sample screenshots)
├── packaging/                    # Template for 使用说明.txt in the versioned ZIP
├── assets/
│   ├── readme/                   # README illustrations and WeChat QR code
│   └── screenshots/              # Interface screenshots (sample data)
├── .github/                      # CI workflow and help issue template
├── LICENSE                       # MIT license
├── README.en.md                  # English guide
└── README.md                     # Chinese home page
```

### Sharing and maintenance

Want to introduce it to friends or post it on social media? Pick and edit a snippet from the [Xiaohongshu / X / WeChat / Douyin copy pack](references/social-sharing.md); the first action is always "tell your AI agent 'check this PC for 360 software', or download it and double-click Start-Check".

The bilingual [project website](https://longxl6.github.io/windows-360-cleaner/en/) is published on GitHub Pages. Maintainers can follow the [publishing and maintenance guide](references/publishing.md) to preview `docs/`, maintain pages and sharing details, and find the Search Console verification and sitemap submission steps. A reachable website does not mean it has been indexed by search engines.

### Safety notes

- On an important PC, create a system restore point and back up browser data first.
- Do not download modified scripts from untrusted mirror sites.
- This project cannot guarantee coverage of every historical version, regional version, or future variant.
- If normal software shows up as "Won't delete: not sure it belongs to 360" (`ReviewOnly`), do not force-delete it by hand; open an issue and attach the checked text from Get help, or the redacted path, file version, and signature information.
- "PUP / potentially unwanted program" is a classification about behavior and user consent; it is not a legal claim that the software is a virus or trojan.

## Contact

If you cannot understand a check result or run into a deletion problem, prefer a public [GitHub Issue](https://github.com/LongXL6/windows-360-cleaner/issues) (click "Get help" in the window first and check the text line by line), so the solution can help other users too. To contact the author through WeChat, click or scan the QR code below.

<p align="center">
  <a href="assets/readme/wechat-longxl.jpg">
    <img src="assets/readme/wechat-longxl.jpg" alt="WeChat QR code for contacting LONG XL" width="260">
  </a>
</p>

> [!NOTE]
> WeChat is a personal contact channel. No paid remote-control service is offered, and never send anyone passwords, verification codes, or unredacted private files. Project problems are still best handled through GitHub Issues.

## License

[MIT](LICENSE)
