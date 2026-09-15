# 更新日志 / Changelog

本文件按版本记录变化，最新版本在最前面。
This file records changes per release, newest first.

## 1.0.0 - 2026-09-13

### 中文

这是第一个带版本号的版本，目前还没有正式发布（是否发布以 GitHub Releases 页面为准）。之前直接从 main 分支下载的 ZIP 没有版本号，可以把它们都看作“1.0.0 之前的版本”。

括号里是这些功能在开发文档和测试里的名字，方便维护者对照。

#### 用 AI Agent：Agent 直接用大白话告诉你删不删

- **新增 `scripts\Show-360Summary.ps1`**：给 Agent 用的只读“大白话翻译器”。它读取检查、删除或检查上次删除结果的记录，打印和窗口同一套文字：每个 360 软件按编号列出，写明“可以删除”还是“不删除：原因”、是什么、删除后会怎样；有地方没检查完时会说明。它不删除任何东西、不启动任何进程、不写文件、不提权、不重启、不上传；末尾 `AGENT:` 开头的行只给 Agent 看，不念给用户。
- **Agent 可以说“建议删除”，但建议不是批准**：`SKILL.md` 新增 “Talking to the user” 一节：用用户的语言说大白话，默认不说技术词；标着“可以删除”的可以说“建议删除”，用户可能还在用的（例如 360 安全浏览器、360 安全卫士）先问一句；标着“不删除”的永远不建议删除，也不想办法绕过。对话里和窗口一样不替用户预先选择：只有用户说出的编号才算，没说的都保留，“都删了吧”只包括“可以删除”的。
- **确认后才删除**：用户说出编号后，`Show-360Summary.ps1 -Delete` 打印和窗口共用的确认内容（要删除的、删除后会怎样、会保留的、删除后不能恢复也不会放进回收站、360 自带卸载程序可能多删的提醒、先关闭 360 的软件、Windows 会弹出窗口问是否允许），以及精确的删除命令。Agent 必须等用户明确回复“确定删除”，才原样运行这条命令一次。选择只取可以删除的内容，并和窗口一样只会为了安全少选；编号和用户看到的那一次检查结果（`-ScanReportHash`）绑定，检查结果变了会拒绝并请 Agent 重新列出；编号不存在、选的都是“不删除”、超过 64 项、缩小后什么都不剩时都不输出命令。文件夹名字里有 `$`、`%` 等特殊符号，或者一个软件就超过 64 项时，会请用户改用“开始检查”窗口。
- **结果照实说**：删除和检查上次删除的结果都必须带上那条命令的退出码（拿不到时写 `unknown`），否则不下结论；拿不到删除记录时说“不确定有没有删干净”，不会说成“没有删除任何东西”；没删掉、不确定、需要重启都不会说成完成。删除后提醒用户保存工作、自己重启；重启后 Agent 再检查一遍，新的对话里用 `-FindLastRemove` 找到这个 Windows 用户最近一次删除。
- `SKILL.md` 规定的最终回复默认只回答三件事：删掉了什么、还剩什么或不确定什么、要不要重启和下一步；完整的统计字段改为用户要“详细信息”时再报告。`agents/openai.yaml` 的默认提示词改为“用大白话告诉我哪些建议删除、哪些不删除，只删除我确认的”。
- README、新手指南、网站和 `使用说明.txt` 改为以 AI Agent 用法为主：对 Agent 说什么、Agent 会怎么回复；“开始检查”窗口是 Agent 不能运行本机命令（例如网页版豆包）时的用法，豆包指南说明怎样让豆包帮你看懂窗口里的文字。

#### 简约窗口：每一行只回答删不删

- **根目录“开始检查”入口**：新增 `开始检查.cmd`（内容相同的英文名副本 `Start-Check.cmd`）。全部解压后双击即可打开图形窗口。如果没有全部解压、找不到 `scripts` 文件夹里的程序文件，会弹窗提示先“全部解压”，不会报一堆看不懂的错误。
- **版本号**：窗口标题和顶部始终显示版本号（`Windows 360 清理工具 v1.0.0`），根目录新增 `VERSION` 文件。
- **单窗口引导**：第一次打开直接开始检查电脑，检查不会删除任何东西。如果上次在窗口里删除后留下了有效的记录，再次打开时首页显示“上次删除的记录”：时间、上次选了几项要删除、保留了几项、之后电脑有没有重启过，按钮是“检查上次删除的结果”“重新检查电脑”和“关闭”。之后还有没拿到结果的删除尝试时，首页会说明。
- **进度与取消**：检查、删除和检查上次删除的结果都只显示“现在正在做哪一步”和已用时间，不显示假的百分比。等 Windows 允许时，标题是“请在 Windows 弹出的窗口里点‘是’”。检查可以点“停止检查”，停止后结果不能用，也不会删除任何东西；删除一旦开始就不能中途停止，窗口也不能关闭，以免说不清删了什么。
- **按软件分组的“删不删”列表**（中文分组清单）：结果按软件分组、默认折叠，只有“勾选”“内容”“删不删”三列。“删不删”只有两种答案：“可以删除”（勾选后显示红色的“要删除”）和“不删除：原因”（例如书签和历史记录、系统驱动、在另一个 Windows 系统里、这是别的软件、请先正常卸载、不能确定是 360 的），后者不能勾选。主界面不再出现专业词：点一行，下方说明区用大白话说它是什么、删除后会怎样；位置、类型、判断依据等放进“更多信息”。打开时一个都不勾选。
- **全选可以删除的**：新增按钮，只勾选可以删除的内容。它和点软件行的方框用同一个检查：只会为了安全少选、不会多选。文件夹里面还有没一起勾选的 360 内容时，这个文件夹会被去掉，并在列表下方用一句话说明；写着“不删除”的永远选不上，也不会自动截断到 64 项。只在用户自己点它时才勾选。
- **怎么选都删不了的内容直接写“不删除”**：检查结果出来时先算一次最多能安全一起删的内容。文件夹里面有要保留的东西、360 自带的卸载程序所在的文件夹不能删时，这一行显示“不删除：里面有要保留的东西”或“不删除：要和它所在的文件夹一起删”，不能勾选，也不算进顶部“可以删除”的数量；Agent 的列表和编号也一样，删除时不会带上它。这一层只会少给、不会多给，删除前的检查不变。
- **提交前检查**：一次最多删除 64 项；勾选了外面的文件夹却没勾选里面可以单独删除的内容、勾选了 360 自带的卸载程序却没勾选它所在的文件夹时，“还需要调整一下”窗口会先说明问题和怎么办，这时还没有删除任何东西。补选只会在用户亲自点“把这 N 项也选上”后进行。
- **确认窗口**：“确定要删除吗？”按软件列出要删除的内容、删除后会怎样和会保留的内容，写明“删除后不能恢复，也不会放进回收站”；选了 360 自带的卸载程序时提醒它可能把同一个软件里没选的部分也一起删掉，不承诺没选的一定不受影响。默认按钮是“取消”，回车和 Esc 都只会取消；点红色的“删除”后，Windows 会弹出窗口问你是否允许。这份确认文字由窗口和 Agent 共用。
- **删除结果页和重启后再检查**（重启复检）：结果页用一个大标题回答删掉了没有：“删除完成”“还差一步：请重启电脑”“有些没删掉”“不确定有没有删干净”或“没有删除任何东西”，下面一句说明、结果确定时一行“删掉 N 项 · 没删掉 N 项 · 不确定 N 项”，以及“接下来”怎么做。失败、不确定和要重启的结果在标题和颜色上都不像成功；运行过 360 自带的卸载程序时，“删除完成”也会说明没选的部分可能被删掉。统计、文件逻辑大小（不等于磁盘实际增加的可用空间）和每一步的操作记录放进“详细信息”。工具不会自动重启：保存工作、手动重启后，点“检查上次删除的结果”。
- **任务记录**：在窗口里删除前，会在记录所在的文件夹保存 `360-cleanup-task-*.json`，只用于重启后找到对应的记录、检查上次删除的结果，不是删除批准。
- **只删了一部分时，重启后也分得清**（部分清理后的复检区分）：“检查上次删除的结果”把结果分成“没删掉”“没法确认或没检查完”“新找到的或有变化的”“你保留的，但不见了”“你保留的”和“已删掉”。你保留的内容还在不算失败；保留的内容不见了会单独列出，标题也不会是绿色；只有直接查看过、确认已经不在的才算“已删掉”。检查只读取信息。
- **没检查完会明确告诉你**（扫描覆盖完整性）：定时任务、后台服务、正在运行的程序、已安装的软件、360 软件的文件信息等检查没有全部完成时，顶部会提示“有些地方没检查完，结果可能不全。”，点“看看是哪些”可以看到是哪里。“没有找到 360 的内容”和“没有找到 360 的内容，但有些地方没检查完”是两种不同的结果，不会说成“已经干净”。
- **获取帮助**（求助摘要）：结果页和出错页的“获取帮助”会在本机另外生成一份问题信息，尽量隐藏用户名、计算机名、SID、邮箱和私人路径等，但可能有遗漏。它用和窗口一样的大白话写明在哪一步、结果怎样、找到几项“可以删除”几项“不删除”，每一项也写着“可以删除”或“不删除：原因”；工具版本、Windows 版本和错误原文等技术信息照原样附在里面。可以先预览、修改、逐行检查，再复制、保存成 `360-cleanup-help-*.txt`、打开求助网页或打开记录所在文件夹。工具不会上传任何内容；这份文字不能用来删除任何东西，也不代表同意删除。
- **更多信息 / 详细信息**：技术字段只出现在二级窗口里。“更多信息”显示单个项目的位置、类型和原始判断依据；“详细信息”显示删除统计、没删掉或没做完的每一项、每一步的操作记录，以及“打开记录所在文件夹”。
- `scripts\Scan-360.cmd` 和 `scripts\Verify-360.cmd` 现在打开同一个图形窗口，分别直接进入“检查电脑”和“检查上次删除的结果”。`scripts\Remove-360.cmd` 命令行方式保持不变。

#### 核心脚本与报告格式

- `scripts\Invoke-360Cleanup.ps1` 新增参数：`-PreviousRemoveReport`（检查某次删除记录里的选择）、`-EmitProgress`（输出进度标记）、`-ElevatedProgressPath`（管理员进程把进度写入临时文件）。
- 报告字段新增：`ToolVersion`、`ScanCoverage`、每个发现项的 `ProductKey`；Remove 报告新增 `Selection`（本次选择、主动保留、未经批准的目标）；Verify 报告新增 `TaskVerification`。`ProductKey` 和 Agent 摘要里的编号只用于分组显示，不会扩大或缩小批准范围。
- 报告仍然是 `SchemaVersion 2`，新增字段都是可选的附加内容。旧报告仍然可以读取，缺少的字段按“未记录”处理。
- Verify 退出码：`0` 没有 `Confirmed` 项目且检查完整；`2` 仍有残留；`3` 结果未知或部分检查没有完成；`4` 本次选择的项目已清除，但出现了新的 `Confirmed` 项目。你主动保留的项目不会导致失败。
- 报告新增 `RunElevated`；普通权限检查时，如果当初是管理员身份扫描，看不到的计划任务、仍在注册表里的服务、读不到路径的同名进程都算“没法确认”，不会算作已清除。保留目录里重新运行的程序（例如重启后又打开的保留浏览器）不算“新找到的”。
- 删除后的即时复查也会检查主动保留的项目（`ImmediatePreservedStillPresent` / `ImmediatePreservedNotConfirmedPresent`），结果页和 Agent 摘要都不会在厂商卸载程序运行后仍声称“没选的项目一定没受影响”。
- 同一条删除命令用已存在的 `-ReportPath` 再运行一次时，会在改动任何东西之前停下。

#### 修复的问题

- **计划任务漏查**：旧版本在遇到第一个 COM 类型动作的计划任务时（Windows 自带任务里很常见）会静默停止检查后面的所有计划任务，可能漏掉 `SoftMgrUpdate*` 这类下载任务。现在逐个检查，单个任务读取失败会记录为“没检查完”。
- **在 Windows 弹出的窗口里点“否”**：在 Windows PowerShell 5.1 上改用保留错误码的方式请求管理员权限，点“否”时结果页会明确显示“没有删除任何东西”和“你在 Windows 弹出的窗口里点了‘否’。”。
- **上次删除的记录**：之后一次没有生成记录的删除尝试（例如点了“否”）不再遮住之前真正需要检查的删除，首页会说明中间有几次没拿到结果的尝试。
- **启动失败提示**：如果 PowerShell 被系统策略或安全软件阻止、窗口没能打开，“开始检查”会弹出大白话说明，而不是没有任何反应；如果当时正在删除，提示会说“不确定有没有删干净”，请重启电脑后再双击“开始检查”，点“检查上次删除的结果”。
- 测试中的中文报告读取、时区相关断言和写死的版本号已修正。

#### 打包与发布

- 新增 `tools\Build-Release.ps1`：生成 `windows-360-cleaner-v<版本>.zip` 和对应的 `.sha256` 校验文件。ZIP 里有一个 `windows-360-cleaner-v<版本>` 文件夹，包含“开始检查”入口、`使用说明.txt`、README、`SKILL.md`、`scripts`（含必需的 `Show-360Summary.ps1`）、`tests`、`references` 等；不包含 `.github`、`docs`、`tools`、`packaging` 和扫描报告。构建前会检查 `VERSION`、核心脚本、界面库和本更新日志的版本号是否一致。
- 新增 `CHANGELOG.md`、`packaging\使用说明.txt` 模板、`tests\Test-Packaging.ps1` 和 `tests\Test-AgentSummary.ps1`（Agent 摘要的编号、禁用词、选择、命令、哈希和结果标题），`tools\New-UiScreenshots.ps1` 按新窗口重新生成示例截图。

#### 安全边界（没有放宽）

- 检查电脑和检查上次删除的结果只读取信息。窗口打开时一个都不勾选，对话里 Agent 也不替用户预先选择；Agent 的“建议删除”不是批准。
- 写着“不删除”的内容永远选不上：点单独一行、点软件行、点“全选可以删除的”或 `Show-360Summary.ps1 -Delete` 都不行。
- 删除前一定先做选择检查（文件夹和里面的内容、要保留的内容、卸载程序和它的文件夹、一次最多 64 项），再明确确认：窗口的确认框默认“取消”，对话里要用户明确回复“确定删除”。之后 Windows 弹出窗口问是否允许，允许后核心脚本重新检查，并核对检查结果的 SHA-256 和每一项的身份。
- 浏览器书签、历史记录等个人资料默认保留。工具不会自动删除、强制删除、自动提权、自动重启、开机自启、常驻后台，也不会收集或上传任何数据。
- 失败、不确定、跳过、没做完和需要重启永远不会显示成成功；删除开始后不能取消，窗口不能关闭；你保留的内容不算失败；获取帮助的文字先脱敏、先预览，从不上传。

### English

This is the first versioned release, and it has not been published yet (the GitHub Releases page is the authority on whether it is). Earlier ZIP downloads taken directly from the main branch had no version number; treat them as "before 1.0.0".

#### With an AI agent: the agent tells you in plain words what to delete

- **New `scripts\Show-360Summary.ps1`**: a read-only plain-words translator for agents. It reads a Scan, Remove or Verify report and prints the same texts as the window: numbered 360 products, each marked "Can be deleted" or "Won't delete: reason", with what it is and what deleting it does, plus a note when some places were not fully checked. It never deletes, starts a process, writes a file, elevates, restarts or uploads anything; the trailing `AGENT:` lines are for the agent and are never read out.
- **The agent may say "I suggest deleting it", but a suggestion is not approval**: `SKILL.md` has a new "Talking to the user" section: plain words in the user's language, no technical terms by default; products marked "can be deleted" may be suggested for deletion, the agent asks first about software the user may still use (such as 360 Secure Browser or 360 Total Security), and it never suggests deleting, or works around, anything marked "won't delete". Like the window, the conversation never preselects anything: only the numbers the user names count, everything else is kept, and "delete everything" only covers items that can be deleted.
- **Deletion only after confirmation**: after the user names numbers, `Show-360Summary.ps1 -Delete` prints the confirmation text shared with the window (what is deleted, what deleting does, what is kept, that it cannot be undone and does not use the Recycle Bin, the warning about the uninstaller that came with 360, closing 360 programs first, the Windows permission prompt) and the exact Remove command. The agent runs that command once, unchanged, only after the user explicitly replies "yes, delete". The choice takes only deletable items and shrinks for safety exactly like the window; the numbers are bound to the check result the user saw (`-ScanReportHash`), so a changed result is refused and listed again; an unknown number, only "won't delete" products, more than 64 items, or nothing left after shrinking prints no command. Folder names with `$`, `%` and similar characters, or one product with more than 64 items, send the user to the Start-Check window.
- **Honest results**: Remove and Verify summaries need the exit code of the command that wrote the report (`unknown` when it was lost), otherwise no conclusion is given; a missing Remove report is "not sure everything was deleted", never "nothing was deleted"; not deleted, not sure and restart-needed are never called finished. After deleting, the agent reminds the user to save their work and restart themselves; after the restart it checks again, and in a new conversation `-FindLastRemove` finds the newest deletion of this Windows user.
- The final reply required by `SKILL.md` now answers three things by default: what was deleted, what is left or not sure, and whether to restart and what comes next; the full statistics are reported when the user asks for details. The `default_prompt` in `agents/openai.yaml` now asks the agent to say in plain words what it suggests deleting and what won't be deleted, and to delete only what the user confirms.
- The README, beginner guides, website and `使用说明.txt` now lead with the AI agent route: what to say to the agent and what it replies. The Start-Check window is the route when the agent cannot run local commands (for example Doubao on the web), and the Doubao guide explains how Doubao can help the user understand the window's text.

#### Simple window: every row only answers "Delete?"

- **Root "Start-Check" launcher**: new `开始检查.cmd` in the package root (identical English-named copy `Start-Check.cmd`). After extracting the whole ZIP, double-click it to open the window. If the ZIP was not fully extracted and the program files in `scripts` are missing, a message box explains that the ZIP must be extracted first.
- **Version number**: the window title and header always show the version (`Windows 360 Cleaner v1.0.0`); a root `VERSION` file was added.
- **Single guided window**: the first launch starts checking the PC right away, and checking never deletes anything. When the last deletion made in the window left a valid record, reopening shows the "Last deletion" home page (time, how many items were selected and kept, whether the PC has restarted since) with "Check the last deletion", "Check the PC again" and "Close". Later deletion attempts without a result are mentioned there.
- **Progress and cancel**: checking, deleting and checking the last deletion show only the current step and the elapsed time (no made-up percentages). While Windows asks for permission, the title says "Click "Yes" when Windows asks for permission". A check can be stopped with "Stop checking"; its result is then not used and nothing is deleted. A deletion cannot be stopped once started and the window cannot be closed, so that it never ends half-way with no clear idea of what was deleted.
- **Grouped "Delete?" list**: results are grouped by product and collapsed, with only three columns: "Select", "Item" and "Delete?". The "Delete?" column has two kinds of answers: "Can be deleted" (shown as "Will be deleted" in red once ticked) and "Won't delete: reason" (for example bookmarks and history, system driver, in another Windows installation, this is other software, uninstall it normally first, not sure it belongs to 360), which cannot be ticked. The main pages no longer show technical terms: clicking a row explains below in plain words what it is and what deleting it does, and the location, type and original reason moved to "More info". Nothing is ticked when the window opens.
- **Select all deletable**: a new button that ticks only items that can be deleted. It uses the same check as the product checkbox and only ever selects less, never more: a folder that still contains unticked 360 items is left out and named in one sentence below the list; "won't delete" rows are never selected, and nothing is silently truncated to 64 items. It ticks only when the user clicks it.
- **Items no choice can delete say "Won't delete"**: when the check result arrives, the largest set of items that can safely be deleted together is worked out once. A folder that contains content that must be kept, or an uninstaller that came with 360 whose folder cannot be deleted, shows "Won't delete: it holds things that are kept" or "Won't delete: it goes together with its folder", cannot be ticked and is not counted in the "can be deleted" headline; the agent's list and numbers do the same and a deletion never takes it. This layer only ever offers less, never more, and the checks before deleting are unchanged.
- **Pre-submit checks**: at most 64 items per deletion; ticking a folder without the separately deletable items inside it, or an uninstaller that came with 360 without its folder is explained in the "A few changes are needed" dialog before anything is deleted. Missing items are added only after the user clicks "Select these N too".
- **Confirmation dialog**: "Delete these items?" lists what is deleted by product, what deleting does and what is kept, and states that deleted items cannot be recovered and do not go to the Recycle Bin; when an uninstaller that came with 360 is selected, it warns that the uninstaller may also remove unselected parts of the same product and never promises that they stay untouched. The default button is "Cancel" (Enter and Esc only cancel); after the red "Delete", Windows asks for permission. The window and the agent share this confirmation text.
- **Deletion result page and checking again after a restart**: one large headline says whether the items were deleted: "Deletion complete", "One more step: restart the PC", "Some items were not deleted", "Not sure everything was deleted" or "Nothing was deleted", followed by one sentence, the line "N deleted · N not deleted · N not sure" when the result is certain, and what to do next. Failed, uncertain and restart-needed results never look like success in headline or colour; when an uninstaller that came with 360 ran, even "Deletion complete" says that unselected parts may have been removed. The statistics, the logical file size (not the free disk space gained) and every recorded step moved to "Details". The tool never restarts the PC: save your work, restart yourself, then click "Check the last deletion".
- **Task record**: before a deletion in the window, a `360-cleanup-task-*.json` record is saved next to the reports. It only locates the reports for the read-only check after a restart; it is not an approval to remove anything.
- **Checking after a partial deletion**: "Check the last deletion" separates "Not deleted", "Could not be confirmed or not fully checked", "Newly found or changed", "Kept by you, but gone", "Kept by you" and "Deleted". Items you kept never make the check fail; kept items that are gone are listed separately and the headline is not green; an item only counts as deleted when a direct read-only probe proves it is gone.
- **Not fully checked is said clearly** (scan coverage): when checks such as timer tasks, background services, running programs, installed programs or 360 file details did not finish, a notice says "Some places were not fully checked; the result may be incomplete." and "Show which ones" lists them. "No 360 content was found" and "No 360 content was found, but some places were not fully checked" are different results, never "the PC is clean".
- **Get help**: "Get help" on result and error pages builds a separate, locally redacted help text (user name, computer name, SIDs, e-mail addresses and private paths hidden as far as possible, though something may be missed). It uses the same plain words as the window: the step, the result, how many items can be deleted and how many won't be, and "Can be deleted" or "Won't delete: reason" for each item; technical details such as the tool and Windows versions and the raw error output are included as they are. You can preview, edit, review, copy, save it as `360-cleanup-help-*.txt`, open the help web page for it, or open the records folder. Nothing is uploaded, and the text can never be used to delete anything or as permission to delete.
- **More info / Details**: technical fields only appear in secondary windows. "More info" shows an item's location, type and original reason; "Details" shows the deletion statistics, every item that was not deleted or not finished, the action log and "Open the records folder".
- `scripts\Scan-360.cmd` and `scripts\Verify-360.cmd` now open the same window directly on "Check the PC" or "Check the last deletion". The command-line `scripts\Remove-360.cmd` flow is unchanged.

#### Core script and report format

- New parameters in `scripts\Invoke-360Cleanup.ps1`: `-PreviousRemoveReport` (verify the selection of an earlier Remove report), `-EmitProgress` (progress markers on stdout) and `-ElevatedProgressPath` (progress file written by the elevated worker).
- New report fields: `ToolVersion`, `ScanCoverage`, `ProductKey` on every finding; Remove reports add `Selection` (selected, preserved and unapproved targets); Verify reports add `TaskVerification`. `ProductKey` and the numbers in the agent summary are for display only and never widen or narrow an approval.
- Reports stay at `SchemaVersion 2`; every addition is optional. Older reports remain readable and missing fields are treated as "not recorded".
- Verify exit codes: `0` no `Confirmed` findings and complete coverage; `2` findings remain; `3` unknown result or incomplete coverage; `4` the selected items are gone but new `Confirmed` findings appeared. Items you kept never cause a failure.
- Reports add `RunElevated`. When a non-administrator verifies a deletion whose scan ran elevated, hidden scheduled tasks, services still registered, and same-name processes with unreadable paths are "could not be confirmed", never removed. A program running again from a kept folder (such as the kept browser reopened after the restart) is not a new finding.
- The immediate check after deleting also re-checks kept targets (`ImmediatePreservedStillPresent` / `ImmediatePreservedNotConfirmedPresent`), so neither the result page nor the agent summary claims unselected items were untouched after a vendor uninstaller ran.
- Running the same removal command again with an existing `-ReportPath` stops before anything changes.

#### Fixed

- **Scheduled tasks skipped**: earlier versions silently stopped checking every later scheduled task after the first task with a COM-handler action (common among built-in Windows tasks), which could miss `SoftMgrUpdate*` download tasks. Tasks are now checked one by one and a task that cannot be read is reported as not fully checked.
- **Clicking "No" at the Windows permission prompt**: elevation now keeps the Windows error code on Windows PowerShell 5.1, so clicking "No" is shown as "Nothing was deleted" with "You clicked "No" when Windows asked for permission."
- **Last deletion record**: a later deletion attempt that produced no record (for example after clicking "No") no longer hides an earlier deletion that still needs checking; the home page mentions the attempts without results.
- **Launch failures**: when PowerShell is blocked by policy or security software and the window cannot open, Start-Check now shows a plain-words explanation instead of doing nothing; if a deletion was running, it says that it is not certain everything was deleted, and asks the user to restart the PC, double-click Start-Check again and click "Check the last deletion".
- Tests now read Chinese reports as UTF-8, avoid time-zone-dependent assertions, and take the expected version from `VERSION`.

#### Packaging and release

- New `tools\Build-Release.ps1` builds `windows-360-cleaner-v<version>.zip` plus a `.sha256` checksum file. The ZIP contains one `windows-360-cleaner-v<version>` folder with the launchers, `使用说明.txt`, the READMEs, `SKILL.md`, `scripts` (including the required `Show-360Summary.ps1`), `tests`, `references` and more, and excludes `.github`, `docs`, `tools`, `packaging` and scan reports. The build refuses to run unless `VERSION`, the core script, the UI library and this changelog agree on the version.
- New `CHANGELOG.md`, `packaging\使用说明.txt` template, `tests\Test-Packaging.ps1` and `tests\Test-AgentSummary.ps1` (agent summary numbering, banned words, selection, commands, hashes and result headlines); `tools\New-UiScreenshots.ps1` regenerates the sample screenshots for the new window.

#### Safety boundaries (not relaxed)

- Checking the PC and checking the last deletion are read-only. The window opens with nothing ticked, and in a conversation the agent never preselects anything; an agent's suggestion is not approval.
- Items marked "won't delete" can never be selected: not by ticking a row or a product row, not by "Select all deletable", and not by `Show-360Summary.ps1 -Delete`.
- Every deletion first passes the selection checks (folders and their contents, content that must be kept, an uninstaller and its folder, at most 64 items), then needs an explicit confirmation: the window's dialog defaults to "Cancel", and in a conversation the user must explicitly reply "yes, delete". Windows then asks for permission, and after elevation the core rescans and verifies the report SHA-256 and every item's identity.
- Browser profiles (bookmarks, history and other personal data) are kept by default. The tool adds no automatic or forced deletion, automatic elevation, automatic restart, autostart, background process, telemetry or upload.
- Failed, unknown, skipped, pending and restart-needed results never look like success; a running deletion cannot be cancelled and the window cannot be closed; items you kept are not failures; the help text is redacted, previewed first and never uploaded.
