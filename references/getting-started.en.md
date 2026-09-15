# Windows 360 Cleaner beginner guide

[Back to the project](../README.en.md) · [简体中文](getting-started.md) · [Changelog](../CHANGELOG.md)

This guide walks you through the local window of **Windows 360 Cleaner v1.0.0** step by step: check the PC, read the "Delete?" answer of each row, decide for yourself what to delete, then restart the PC yourself and check the last deletion. You do not need to know PowerShell, GitHub, JSON, or AI agents, and you never have to type a command.

> [!NOTE]
> Every screenshot in this guide is a **screenshot with sample data**. The window screenshots carry a yellow "示例数据截图" (sample-data screenshot) banner at the top, and nothing on a real PC was checked or deleted to make them. The items and numbers on your PC will be different.
>
> The screenshots show the Chinese window. The window is in Chinese when the Windows display language is Chinese, and in English otherwise. This guide uses the English labels and adds the Chinese label in parentheses so you can match them to the screenshots.

## Contents

- [Choose how to use it](#choose-how-to-use-it)
- [Before you start](#before-you-start)
- [Step 1: Download and extract the whole ZIP](#step-1-download-and-extract-the-whole-zip)
- [Step 2: Double-click Start-Check](#step-2-double-click-start-check)
- [Step 3: Understand the check result](#step-3-understand-the-check-result)
- [Step 4: Decide what to delete](#step-4-decide-what-to-delete)
- [Step 5: Confirm the deletion](#step-5-confirm-the-deletion)
- [Step 6: Read the deletion result](#step-6-read-the-deletion-result)
- [Step 7: Restart yourself, then check the last deletion](#step-7-restart-yourself-then-check-the-last-deletion)
- [Where the record files are saved](#where-the-record-files-are-saved)
- [Need help: Get help](#need-help-get-help)
- [What this tool never does](#what-this-tool-never-does)
- [Troubleshooting](#troubleshooting)
- [Advanced: agents and the command line](#advanced-agents-and-the-command-line)

## Choose how to use it

This project is first of all an **AI agent skill**; the local window is for people whose agent cannot reach their PC, or who do not use an agent. Both say the same things: every 360 product either "can be deleted" or "won't delete: reason", checking never deletes anything, and every deletion needs your own confirmation.

| Your situation | What to do |
|---|---|
| Your AI agent can run PowerShell on this PC (for example Codex) | Just tell it: "Check this PC for 360 software, tell me in plain words what you suggest deleting and what won't be deleted, and delete only what I confirm." It lists numbered products and tells you what it suggests deleting and what won't be deleted; you reply with numbers, it shows you a confirmation text first, and it deletes only after you reply "yes, delete". After the restart, tell it "it has restarted" and it checks again. You can skip the window steps of this guide; an example conversation is under ["Use it with an AI agent" on the project page](../README.en.md#use-it-with-an-ai-agent-recommended) |
| Your agent cannot run local commands (for example Doubao on the web), or you do not use an agent | Use the Start-Check window with the 7 steps below. Doubao can help you understand the window's text; see the [Doubao and general agent guide](doubao.md) (in Chinese, with an English prompt) |

When you use an agent, remember: it may say "I suggest deleting it", but only the numbers you name are deleted; it never suggests deleting, or works around, anything marked "won't delete"; and it never restarts your PC.

## Before you start

**What it is:** a free, open-source AI agent skill that also comes with a local window. It looks for 360-family software on your PC, such as 360 Total Security / 360 Antivirus, the 360 browsers, 360 Software Manager, 360 Huabao / Duohui screen saver, and the 360 program files inside the winToolBox toolbox, together with the programs that run at startup, background services, and tasks that run on a timer they leave behind. **It deletes only the items you tick and confirm yourself.**

**What you need:**

- Windows 10 or Windows 11.
- Windows PowerShell 5.1, which comes with Windows 10/11. There is nothing extra to install.
- No installation of the tool itself: extract the ZIP and use it.
- Windows asks for permission only when you confirm a deletion. Checking does not need it.
- A check usually takes a minute or two; it can take longer on a slower PC or one with many files.
- Use the Windows PC you want to check. A phone can display this guide but cannot run the tool, and it does not run on macOS or Linux.

**The whole flow has 7 steps, and only step 5 deletes anything:**

| Step | What you do | Does it delete anything? |
|---|---|---|
| 1. Download and extract | Download the ZIP, right-click it, and extract everything | No |
| 2. Start the check | Double-click Start-Check and wait for the check to finish | No |
| 3. Understand the result | Read the "Delete?" answer of each row, and click a row to read the explanation below | No |
| 4. Tick items | Tick only the items you are sure you do not want | No, ticking is only a choice |
| 5. Confirm the deletion | Read the "Delete these items?" dialog, click "Delete", then click "Yes" when Windows asks for permission | **Yes**: the tool deletes only the items you ticked (a ticked uninstaller that came with 360 may also remove unticked parts of its product), and they cannot be recovered |
| 6. Read the result | Read the headline of the result page and what to do next | No |
| 7. Restart and check again | Restart yourself, double-click Start-Check again, and click "Check the last deletion" | No |

## Step 1: Download and extract the whole ZIP

1. Open the [project page](https://github.com/LongXL6/windows-360-cleaner) and check that the owner in the address is `LongXL6` and the repository name is `windows-360-cleaner`.
2. Click [Download ZIP](https://github.com/LongXL6/windows-360-cleaner/archive/refs/heads/main.zip), or choose **Code → Download ZIP** on the project page. Downloading a public project needs no GitHub account. After the maintainer publishes a release, you can also download a ZIP with the version number in its name from the project's [Releases page](https://github.com/LongXL6/windows-360-cleaner/releases).
3. Right-click the downloaded ZIP file and choose **Extract All** (on Chinese Windows: 全部解压缩, sometimes shown as 全部解压). Extract it somewhere easy to find, such as the Desktop.
4. Open the extracted folder and find **开始检查** (its type is shown as "Windows Command Script"). The **Start-Check** file next to it is an identical copy with an English name; you can double-click either one. With the main-branch ZIP you may first need to open one more folder, such as `windows-360-cleaner-main`.

Do not double-click anything inside the ZIP preview window, and do not copy only the Start-Check file somewhere else: it needs the `scripts` folder next to it. Downloading and extracting do not check or delete anything.

![Screenshot with sample data: the extracted folder, with 开始检查 in the file list](../assets/screenshots/01-start-entry.png)

*Screenshot with sample data: the extracted folder. Your file list may look slightly different (for example, the main-branch ZIP has a few more folders); you only need to find 开始检查 or Start-Check.*

## Step 2: Double-click Start-Check

Double-click **Start-Check** (or **开始检查**). The window title shows the version, for example `Windows 360 Cleaner v1.0.0` (on Chinese Windows `Windows 360 清理工具 v1.0.0`).

- **Opening it starts checking the PC automatically.** Checking only reads information, deletes nothing, and does not need Windows permission.
- The window shows only the step it is on right now and the elapsed time. It does not show a made-up percentage.
- To stop, click **Stop checking** (停止检查). The page then says **Check stopped** (检查已停止): the check did not finish, its result cannot be used, and nothing was deleted. You can click **Check the PC again** (重新检查电脑) later.
- If you deleted items with this tool before and a usable record of that deletion is found, the window opens on the **Last deletion** (上次删除的记录) page instead of checking. See [Step 7](#step-7-restart-yourself-then-check-the-last-deletion).
- Only one window can be open at a time. If you see **The tool is already open.** (本工具已经打开了。), find the window that is already open.

If Windows shows a security warning, read [Troubleshooting](#troubleshooting) first.

![Screenshot with sample data: checking the PC, showing the current step, the elapsed time, and a Stop checking button](../assets/screenshots/02-scan-progress.png)

*Screenshot with sample data: checking the PC, showing only the current step and the elapsed time; the green bar only moves back and forth to show it is still working and is not a percentage.*

## Step 3: Understand the check result

When the check finishes, one sentence appears at the top of the window, for example "360 software found: 2 product(s) have items you can delete" (找到 2 个可以删除的 360 软件), followed by "Tick what to delete, then click "Delete selected". The tool does not delete unticked items." **Nothing is ticked when the window opens.**

![Screenshot with sample data: "2 products have items you can delete", the check result grouped by software with only the Select, Item, and Delete? columns; the 3 Duohui items are ticked and show Will be deleted, the area below explains the selected row, and the bottom line says 3 items are selected for deletion](../assets/screenshots/03-scan-results.png)

*Screenshot with sample data: the check result. To demonstrate the later steps, two products are expanded and the 3 items of "360 画报 / 多绘屏保" (360 Huabao / Duohui screen saver) are already ticked in this picture; when you open the tool yourself, products are collapsed and nothing is ticked.*

### How to read the list

- The list has only three columns: **Select** (勾选), **Item** (内容), and **Delete?** (删不删).
- Results are grouped by software, for example "360 Secure Browser" or "360 Huabao / Duohui screen saver". Products are collapsed; click a product name to see each item inside it.
- Click any row, and the area below explains what it is and what happens if it is deleted. For the location, evidence, and other technical details, click **More info** (更多信息) next to it.

### What the Delete? column means

The column has only two kinds of answers. **Only "Can be deleted" can be ticked.**

| Shown | What it means | Can it be ticked? |
|---|---|---|
| Can be deleted (可以删除) | Something 360 left behind that can be deleted. **The window does not decide for you; the decision is yours.** Once ticked, it shows "Will be deleted" (要删除) in red | Yes, if you decide to |
| Won't delete: not sure it belongs to 360 (不删除：不能确定是 360 的) | The name or location looks like 360, but it is not certain that it really belongs to 360. To avoid deleting the wrong thing, it is not deleted | No |
| Won't delete: bookmarks and history (不删除：书签和历史记录) | Browser bookmarks, history, saved passwords, and other personal data | No |
| Won't delete: in another Windows installation (不删除：在另一个 Windows 系统里) | Found in another Windows installation on this PC, for example one on another disk | No |
| Won't delete: system driver (不删除：系统驱动) | Deleting a system driver directly can cause blue screens or stop Windows from starting | No |
| Won't delete: this is other software (不删除：这是别的软件) | For example the winToolBox toolbox itself. The whole program is never deleted; the separate 360 parts inside it are listed as their own items | Not as a whole |
| Won't delete: details incomplete (不删除：信息不完整) | The details of this item could not be confirmed, so it is not deleted to avoid deleting the wrong thing | No; you can check the PC again later |
| Won't delete: uninstall it normally first (不删除：请先正常卸载) | This program still looks installed. Uninstall it in Windows Settings → Apps first, then check the PC again | No |
| Won't delete: it holds things that are kept (不删除：里面有要保留的东西) | It could be deleted on its own, but it contains things the tool does not delete, and deleting it would delete those too | No |
| Won't delete: it goes together with its folder (不删除：要和它所在的文件夹一起删) | An uninstaller that came with 360 can only be deleted together with its folder, and that folder cannot be deleted | No |

Occasionally you may also see "Won't delete: please check again" (不删除：请重新检查). It cannot be ticked either; click **Check the PC again**.

### When nothing is found

- **No 360 content was found** (没有找到 360 的内容): nothing on this PC looks like the 360 software this tool knows. You can close the tool.
- **No 360 content was found, but some places were not fully checked** (没有找到 360 的内容，但有些地方没检查完): the result may be incomplete. You can check again a little later; if it keeps happening, click **Get help**.
- If the yellow notice "Some places were not fully checked; the result may be incomplete." (有些地方没检查完，结果可能不全。) appears above the results, click **Show which ones** (看看是哪些) next to it. The items that are listed are correct, but something may have been missed.
- If every item found says "Won't delete", the headline is "Some 360-related items were found, but none of them will be deleted" (找到了一些 360 相关的内容，但都不删除). The reason is shown on each row; you can simply close the window.

## Step 4: Decide what to delete

If you do not understand the result or do not want to delete anything, tick nothing and click **Close** (关闭). Nothing is deleted.

If you want to delete items:

1. Click the box at the left of a row to tick an item you are sure you do not want. Click it again to untick it.
2. Clicking the box in front of a product ticks the items of that product that **can be deleted and can safely be deleted together**; clicking it again unticks them all. Other products are not affected.
3. **Select all deletable** (全选可以删除的) ticks only items that say "Can be deleted"; rows that say "Won't delete" are never ticked. It only ever selects less for safety, never more. A folder that contains things that must be kept, or an uninstaller that came with 360 whose folder cannot be deleted, already says "Won't delete" on its row and is never selected. Occasionally a product row click does not tick an item for you (for example a folder that also contains unticked items of another product); one sentence below the list explains why. It ticks only when you click it; the window never selects everything by itself.
4. The bottom of the window shows `N item(s) selected for deletion.` (已选 N 项要删除。). At most 64 items can be deleted at a time.
5. If you ticked the wrong items, click **Clear all** (全部不选) and tick again.
6. When you are done, click **Delete selected...** (删除选中的内容…). This does not delete anything yet: the tool first checks your selection, then opens the "Delete these items?" dialog.

A browser's "program files" and its "personal data (bookmarks, history, ...)" are two separate items. Without its program files the browser cannot start; personal data is not deleted and cannot be ticked here.

If you tick an **uninstaller that came with 360**, the sentence at the top turns orange: it may also remove parts of the same product that you did not tick.

### If "A few changes are needed" appears

After you click **Delete selected...**, the tool checks your selection first. If something needs to change, the **A few changes are needed** (还需要调整一下) dialog explains the problem and what to do. **At this point nothing has been deleted.**

| Problem shown | Why | What to do |
|---|---|---|
| More than 64 items are ticked | At most 64 items can be deleted at a time | Click **Go back and change** (返回修改) and untick some, for example delete one product at a time. Afterwards, click **Check the PC again** and delete the next batch |
| You ticked a folder that still contains items you did not tick and that can be deleted on their own | Deleting the folder would delete them too | Click **Select these N too** (把这 N 项也选上), or click **Go back and change** and do not delete the folder |
| You ticked an uninstaller that came with 360 but not the folder it is in | The uninstaller must be deleted together with its folder | Tick the folder as well (click **Select these N too** when it is offered), or click **Go back and change** and untick the uninstaller |

The tool only adds ticks after you click **Select these N too** yourself. It never ticks anything on your behalf.

## Step 5: Confirm the deletion

The **Delete these items?** (确定要删除吗？) dialog lists:

- **To delete** (要删除的): the items to delete, grouped by product;
- **After deleting** (删除后): what happens after each item is deleted;
- **Deleted items cannot be recovered and do not go to the Recycle Bin** (删除后不能恢复，也不会放进回收站);
- **Kept** (会保留的): what you did not select and what is not deleted;
- a reminder to close the 360 programs first and back up bookmarks or other data you need;
- that Windows asks for permission after you click "Delete".

If you ticked an uninstaller that came with 360 (for example the uninstaller that came with the Duohui screen saver), red text warns you that it may also remove parts of the same product that you did not select. Those parts are then listed separately and are not described as kept.

![Screenshot with sample data: the Delete these items? dialog; the default button is Cancel, next to a red Delete button](../assets/screenshots/04-confirm-delete.png)

*Screenshot with sample data: the "Delete these items?" dialog lists the 3 items to delete, what happens after deleting them, and what is kept: 360 Secure Browser, which you did not select, and two items marked "not sure it belongs to 360".*

- If you are unsure about anything, click **Cancel** (取消). It is the default button; pressing Enter or Esc also only cancels, and nothing is deleted.
- Only after checking every item, click the red **Delete** (删除) button.
- When Windows asks for permission (User Account Control), make sure it is for what you just did, then click "Yes". If you click "No", the result page says "Nothing was deleted".
- If your account has no administrator rights, ask the administrator of this PC.

### While deleting

- Until Windows gives permission, the page title is "Click "Yes" when Windows asks for permission" (请在 Windows 弹出的窗口里点“是”); "Deleting..." (正在删除…) is shown only when deleting really starts, together with the current step and the elapsed time.
- After permission is given and before anything is deleted, the tool checks once more that the items you ticked have not changed. If something changed or disappeared, it stops before deleting anything.
- **Once deleting starts, it cannot be stopped**, and the window cannot be closed until it ends. Please wait, and do not shut down the PC.

## Step 6: Read the deletion result

![Screenshot with sample data: deletion complete, all 3 selected items were deleted, with what to do next below](../assets/screenshots/05-cleanup-result.png)

*Screenshot with sample data: deletion complete. The statistics and the record of every step are under Details.*

The result page gives a large headline saying whether the items were deleted, one sentence below it, and what to do next. Failed, uncertain, and restart-needed results **never look like success, in headline or colour**.

| Headline | What it means | Next step |
|---|---|---|
| Deletion complete (删除完成, green) | Everything you selected was deleted, and the check right after deleting confirmed it. The tool did not touch what you did not select | You can close the tool; when convenient, save your work, restart yourself, then click "Check the last deletion" |
| Deletion complete (删除完成, orange) | Everything you selected was deleted, but an uninstaller that came with 360 ran, or some items you did not select could not be confirmed as still present afterwards; the page says which | As above; if you still need the items you did not select, check them after the restart |
| One more step: restart the PC (还差一步：请重启电脑) | Some items are in use and can only be deleted after a restart | Save your work, restart yourself, then click "Check the last deletion" |
| Some items were not deleted (有些没删掉) | Some items were not deleted; the reasons are listed below (items with the same reason are merged into one line) | Restart the PC first, then click "Check the last deletion"; if it still does not work, click "Get help". Do not keep forcing deletion |
| Not sure everything was deleted (不确定有没有删干净) | No trustworthy deletion result was received, or the check after deleting could not run | **Do not treat it as done.** Restart and check again |
| Nothing was deleted (没有删除任何东西) | For example, you clicked "No" when Windows asked for permission | You can check the PC again, or just close |

- The line `N deleted · N not deleted · N not sure` (删掉 N 项 · 没删掉 N 项 · 不确定 N 项) is shown only under "Deletion complete" and "Some items were not deleted", never under the uncertain or restart-needed results.
- The **Details** (详细信息) window has the statistics (deleted files, folders, background services, scheduled tasks, settings left by 360, and so on), every item that was not deleted or not finished, the record of every step, and **Open the records folder** (打开记录所在文件夹).
- **Logical file size** is the size of the deleted files themselves and is **not** the same as the free disk space actually gained. When some places could not be measured, the numbers are minimum values.

Buttons at the bottom of the result page (their order and number depend on the result):

| Button | What it does |
|---|---|
| Close (关闭) | Closes the window |
| Check the last deletion (检查上次删除的结果) | Checks right away and never deletes anything. For items that need a restart, check again after restarting |
| Details (详细信息) | Shows the statistics, the items that were not deleted, and every recorded step |
| Get help (获取帮助) | Creates the problem information with personal details hidden as far as possible; see [Need help](#need-help-get-help) |
| Check the PC again (重新检查电脑) | Shown when nothing was deleted, or when no deletion result could be read (then "Check the last deletion" and "Details" are not offered); checks the PC again |

## Step 7: Restart yourself, then check the last deletion

The tool **never restarts your PC automatically**.

1. Save the documents you are working on, close other programs, and restart the PC yourself.
2. After the restart, go back to the extracted folder and double-click **Start-Check** again.
3. When the record of your last deletion is found, the **Last deletion** (上次删除的记录) page appears: the time, how many items were selected for deletion and how many were kept, and whether the PC has restarted since then.
4. Click **Check the last deletion** (检查上次删除的结果).

![Screenshot with sample data: reopened after a restart, showing the record of the last deletion with the Check the last deletion, Check the PC again, and Close buttons](../assets/screenshots/06-home-after-restart.png)

*Screenshot with sample data: reopened after a restart. "The PC has restarted since then, so you can check the result now." (电脑已经重启过，可以检查结果了。) means you can start checking.*

| Button | What it does |
|---|---|
| Check the last deletion (检查上次删除的结果) | Checks item by item whether the items selected last time are gone. Start with this one. Checking never deletes anything |
| Check the PC again (重新检查电脑) | Checks the PC again to see what is on it now, so you can decide again |
| Close (关闭) | Closes the window |

If the page says the PC has not restarted yet, save your work and restart the PC yourself before checking the result.

If the **Last deletion** page does not appear when you reopen the tool (for example because the last deletion left no usable record), the tool checks the PC again right away, so you can see what is there now. If the last deletion was made in an AI agent conversation, the window's home page does not show it; go back to the agent and say "check the last deletion". If the **Last deletion** page appears anyway, it shows an earlier deletion made in the window, so check its time.

![Screenshot with sample data: checking the last deletion; everything selected last time is gone and the 1 item you kept is still there](../assets/screenshots/07-verify-result.png)

*Screenshot with sample data: the 3 Duohui screen saver items are under "Deleted" (已删掉); "360 Secure Browser program files" (360 安全浏览器程序文件) is under "Kept by you" (你保留的) with the state "Still there" (还在), which is normal and does not count as a failed deletion.*

### Possible headlines

| Headline | What it means | Next step |
|---|---|---|
| Everything selected last time is gone (上次选的都删干净了) | Everything selected last time was confirmed as deleted (the headline is orange when an item you kept is gone, and the sentence below says so) | You can close the tool |
| Everything selected last time is gone, but some places were not fully checked (上次选的都删干净了，但有些地方没检查完) | Deleted, but some places were not fully checked this time | Check once more later |
| Everything selected last time is gone, but N new 360 item(s) were found (上次选的都删干净了，但又找到 N 项新的 360 内容) | Everything selected last time was deleted, but new items were found this time | Click "Check the PC again", then decide whether to delete them |
| N item(s) were not deleted (还有 N 项没删掉) | Some of the items selected last time are still there or have changed | Restart the PC, open the tool and check again; if they still cannot be deleted, click "Get help" |
| N item(s) could not be confirmed as deleted (有 N 项没法确认有没有删掉) / Everything selected last time looks gone, but this check was not complete (上次选的看起来都删掉了，但这次检查没做完整) | The check could not confirm the result, so it must not be treated as all gone | Restart the PC, open the tool and check again; if it still does not work, click "Get help" |
| The record of the last deletion cannot be used, so the whole PC was checked again (上次删除的记录用不了，已经重新检查了一遍电脑) | For example, the last record cannot be found or read, has an incompatible version, was created by a version before 1.0.0, or the deletion was done by another Windows user, so items cannot be checked one by one; the page shows the result of checking the PC again | Click "Check the PC again" to see what is there now |

When there is no record of a last deletion and the whole PC is checked directly (for example with `scripts\Verify-360.cmd`), the headline can be "No 360 content that needs attention was found" (没有找到还需要处理的 360 内容), "N 360 item(s) are still on this PC" (电脑上还有 N 项 360 的内容), "No 360 content that needs attention was found, but some places were not fully checked" (没有找到还需要处理的 360 内容，但有些地方没检查完), or "Nothing that can be deleted was found, but N 360 item(s) that are not deleted remain" (没有找到可以删除的 360 内容，但还有 N 项不删除的内容; for example a program that is still installed and must be uninstalled normally first). The list is then split into **360 items still on this PC** (现在还有的 360 内容), **Could not be confirmed or not fully checked** (没法确认或没检查完), and **Won't be deleted** (不删除的). They are not labelled as new.

Checking does not need Windows permission. If the check and deletion ran as administrator, scheduled tasks, background services, or programs that a normal account cannot see are listed under "Could not be confirmed or not fully checked", never as deleted.

### How the list is grouped

The list shows only the groups that have items, in this order:

- **Not deleted** (没删掉): you selected it, but it is still there. If files were in use, save your work, restart yourself, and check again.
- **Could not be confirmed or not fully checked** (没法确认或没检查完): the item could not be read or confirmed. Do not treat it as deleted.
- **Newly found or changed** (新找到的或有变化的): 360 items found for the first time, or an item at the same place that is different from last time.
- **Kept by you, but gone** (你保留的，但不见了): items you did not select last time that are gone now (for example, removed together by an uninstaller that came with 360). Reinstall them if you still need them.
- **Kept by you** (你保留的): items you did not select last time that are still there. That is normal, and **it does not count as a failed deletion**.
- **Deleted** (已删掉): a direct check confirmed that the item is no longer present.

**Checking only reads information and never deletes anything.** To handle new or remaining items, click **Check the PC again**, then decide, tick, and confirm again in the new result. Your earlier confirmation never carries over to new items.

## Where the record files are saved

You do not need to open these record files. The tool saves them on your **Desktop**; if the Desktop is not available, in the temporary folder `%TEMP%`. Click **Open the records folder** in the Details or Get help window to find them.

| File name | What it is |
|---|---|
| `360-cleanup-scan-<date>-<time>-<id>.json` | Record of checking the PC |
| `360-cleanup-remove-<date>-<time>-<id>.json` | Record of the deletion |
| `360-cleanup-verify-<date>-<time>-<id>.json` | Record of checking the last deletion |
| `360-cleanup-task-<date>-<time>-<id>.json` | Deletion task record. It is only used after a restart to find the matching records when you check the last deletion, and **it can never be used to delete anything** |
| `360-cleanup-help-<date>-<time>-<id>.txt` | Problem information you saved from Get help |

- New records never overwrite older files, and the tool never uploads records.
- Records contain the tool version (`ToolVersion`). Records from older versions can still be read. Versions before 1.0.0 did not record which items you ticked, so an older deletion cannot be checked item by item, but checking the whole PC still works.
- Do not edit the records by hand. If the check result changes while you are ticking items, the tool stops, shows "The check result changed" (检查结果被改动了), and asks you to check the PC again. Nothing is deleted.
- Records contain file paths from your PC and similar information, so **do not share the original record files publicly**. If your Desktop is managed by OneDrive or another sync service, these records are synced like any other Desktop file.

## Need help: Get help

The check result page, the deletion result page, the page that checks the last deletion, and error pages all have a **Get help** (获取帮助) button.

1. Click **Get help**. The tool creates separate problem information on your PC with the tool version, the Windows version, the step you reached, the result, and the related items. Your user name, computer name, SIDs, e-mail addresses, private paths, and similar details are hidden as far as possible, but something may be missed.
2. **Check the preview line by line.** You can edit the preview directly and delete anything you do not want others to see.
3. Click **Copy** (复制), or **Save as a file** (保存成文件; it is saved in the records folder with a name like `360-cleanup-help-<date>-<time>-<id>.txt`).
4. To ask for help on GitHub, click **Open the help web page** (打开求助网页). It only opens a fixed help page in your browser; the tool sends nothing. Submitting an issue requires a GitHub account. Fill in the version from the window title (for example v1.0.0) and the step where you got stuck, then paste the text you checked.

Please note:

- Automatic redaction cannot be guaranteed to catch everything. Always check again yourself before sending.
- The original records stay on your PC and are not modified.
- The problem information is only for discussion. It **cannot be used to delete anything** and is never an approval to delete.
- Public issues are visible to everyone. Do not upload the original record files, passwords, browser data, or private files unrelated to the problem.

You can also ask for help through the [author contact on the project page](../README.en.md#contact).

## What this tool never does

- It never ticks anything for you when it opens, and never decides for you what to delete.
- It never searches for and deletes things because their names contain "360"; ordinary photos, games, panoramic videos, or folders are not targets just because their names contain 360.
- It never deletes browser bookmarks, history, or other personal data; they show "Won't delete: bookmarks and history" and cannot be ticked here.
- It never deletes rows that say "Won't delete", such as "not sure it belongs to 360", "system driver", or "in another Windows installation".
- It never restarts your PC automatically, never runs at startup, never stays in the background, and never uploads anything.
- It never reports items that were not deleted, skipped, unfinished, or unconfirmed as deleted.
- It is not antivirus software, and it cannot guarantee to find every past or future version of 360 software.

## Troubleshooting

| Situation | What to do |
|---|---|
| Double-clicking Start-Check does nothing, or a message says "The program files in the scripts folder were not found" (没有找到 scripts 文件夹中的程序文件) | Usually the ZIP was not fully extracted, or only the Start-Check file was copied. Go back to the ZIP, right-click it, choose **Extract All**, and double-click Start-Check in the extracted folder |
| A message says Windows PowerShell could not run the cleaner | It may be blocked by a system policy or security software, or files may be damaged. Do not turn off security protection to run the tool; run `scripts\Scan-360.cmd` to see the error, or take a screenshot and ask for help. On a work or school PC, ask the administrator. If something was being deleted when it appeared, it is not certain that everything was deleted: restart the PC, double-click Start-Check again and click **Check the last deletion** (检查上次删除的结果) |
| It does not open on a phone, macOS, or Linux | The tool runs only on Windows 10/11 PCs. Download the ZIP on the Windows PC you want to check |
| Windows shows a security warning (for example "The publisher could not be verified" or "Windows protected your PC"), or says an organization policy blocks it | This happens because the scripts are not digitally signed or the PC has a security policy. First make sure the ZIP came from this project's page; if you are not sure, do not run it. **Do not turn off your antivirus or SmartScreen, or change system policies, to run this tool.** On a work or school PC, ask the administrator |
| "The tool is already open." (本工具已经打开了。) | Only one window can be open at a time. Continue in the window that is already open, or close it first |
| You clicked **Stop checking** and see "Check stopped" (检查已停止) | The check did not finish, its result cannot be used, and nothing was deleted. Click **Check the PC again** |
| "Some places were not fully checked; the result may be incomplete." (有些地方没检查完，结果可能不全。) | The items that are listed are correct, but something may have been missed. Click **Show which ones**, and check again later. Do not turn off security software or change permissions because of this |
| More than 64 items are ticked | At most 64 at a time. Work in batches: delete one product, check the PC again, then delete the next batch |
| "A few changes are needed" (还需要调整一下) says a folder still contains items that are not ticked | Click **Select these N too**, or click **Go back and change** and do not delete the folder. See [Step 4](#step-4-decide-what-to-delete) |
| You clicked "No" when Windows asked for permission and see "Nothing was deleted" (没有删除任何东西) | Nothing was deleted. To continue, check the PC again, then tick and confirm again; without administrator rights, ask the PC's administrator |
| The deletion result says "Not sure everything was deleted" (不确定有没有删干净) | Do not treat it as done. Save your work, restart yourself, double-click Start-Check again, and click "Check the last deletion"; if the **Last deletion** page does not appear, look at the result of checking the PC again to see what is there |
| The check says "N item(s) could not be confirmed as deleted" (有 N 项没法确认有没有删掉) | Save your work, restart yourself, and check again; if it still cannot be confirmed, click **Get help** |
| You want to close the window while deleting, but it will not close | The window cannot be closed while deleting, so that you never end up half-way with no clear idea of what was deleted. Wait until it finishes |
| You cannot find the record files | Click **Open the records folder** in the Details or Get help window. They are on the Desktop by default, or in `%TEMP%` when the Desktop is not available |
| "The check result changed" (检查结果被改动了) | The check result was modified while you were ticking items. Nothing was deleted; check the PC again |
| 360 software or the Duohui screen saver comes back after a while | Check the PC again and look for new programs that run at startup, tasks that run on a timer, or background services; click **Get help** if needed. Advanced notes are in [troubleshooting](troubleshooting.md) |
| After deleting with an agent, it says "done", but you are not sure it really did anything | If the agent did not show you a check result, and did not show you a confirmation text before deleting, do not treat anything as checked or deleted. You can use the Start-Check window to check the PC again |
| You still do not understand something | Click **Get help**, check the text, then [open a help issue](https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml) (GitHub sign-in required) |

## Advanced: agents and the command line

Without an agent, Start-Check is all you need. The notes below are for people familiar with AI agents or the command line:

- When an AI agent uses this project, have it read [SKILL.md](../SKILL.md) first. It runs the check, then uses `scripts\Show-360Summary.ps1` to turn the result into the same plain words as the window; that script also builds the removal command from the numbers you named, and the agent runs it only after your explicit "yes, delete". For Doubao and other agents that cannot install skills, see the [Doubao and general agent guide](doubao.md) (in Chinese, with an English prompt). An ordinary chatbot may not be able to operate your PC; if an agent says it is "done" but cannot show a command result or record, do not treat it as having run anything.
- `scripts\Scan-360.cmd` and `scripts\Verify-360.cmd` open the same window, going straight to "Check the PC" or "Check the last deletion", and also keep a console window with the output. They are useful when the window does not open.
- `scripts\Remove-360.cmd` is the advanced route for a "whole reviewed report": it processes every target in the report that is still `Confirmed`, so it is not suitable for beginners who want to delete only some items.
- To check one specific deletion from an agent or the command line, use `scripts\Invoke-360Cleanup.ps1 -Mode Verify -PreviousRemoveReport <path to the Remove report>`. Parameters, exit codes, and fields are described in [SKILL.md](../SKILL.md).
- For access denied, a screen saver that keeps coming back, multiple Windows installations, and other advanced problems, see [troubleshooting.md](troubleshooting.md).
