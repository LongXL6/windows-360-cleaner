<p align="center">
  <strong>简体中文</strong> · <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="assets/readme/windows-360-cleaner-hero.jpg" alt="AI Agent 扫描、确认、安全清理并验证 Windows 软件的流程" width="100%">
</p>

<h1 align="center">Windows 360 Cleaner：360 软件扫描与清理 Skill</h1>

<p align="center">
  给 Codex、豆包和其他 AI Agent 使用的 Windows 360/Qihoo 软件安全清理技能包<br>
  <strong>先扫描 · 人工确认 · 精确删除 · 重启验证 · 输出清理账单</strong>
</p>

<p align="center">
  <a href="https://github.com/LongXL6/windows-360-cleaner/actions/workflows/validate.yml"><img src="https://github.com/LongXL6/windows-360-cleaner/actions/workflows/validate.yml/badge.svg" alt="Validate"></a>
  <img src="https://img.shields.io/badge/Agent-Skill-22c55e" alt="Agent Skill">
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078d4" alt="Windows 10 | 11">
  <img src="https://img.shields.io/badge/PowerShell-5.1%2B-2563eb" alt="PowerShell 5.1+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-f59e0b" alt="MIT License"></a>
</p>

> [!IMPORTANT]
> 这是一个开源 **AI Agent Skill 技能包**，包含可在 Windows 上运行的 PowerShell 脚本。你可以让 Agent 协助，也可以自己双击脚本开始扫描。支持 Windows 10/11 与 PowerShell 5.1+，无需购买服务。

## 第一次使用：先拿到扫描报告

1. [下载仓库 ZIP](https://github.com/LongXL6/windows-360-cleaner/archive/refs/heads/main.zip)，右键选择“全部解压”；进入解压后的文件夹。
2. 打开 `scripts`，双击 **`Scan-360.cmd`**。扫描不删除软件，不需要管理员权限；结束后会写入 JSON 报告。
3. 按窗口里的 **`Report:`** 路径找到报告（默认在桌面），先读结果，再决定是否继续。

**扫描报告生成就是第一步完成。** `Confirmed` 表示有匹配证据，仍需你批准；`ReviewOnly` 表示仅供复核。看不懂时先停在这里。

[新手图文步骤与常见问题](references/getting-started.md) · [让豆包帮忙解释](references/doubao.md) · [提交脱敏求助](https://github.com/LongXL6/windows-360-cleaner/issues/new?template=help.yml)

浏览器书签和个人资料默认保留；后续 `Remove` 是永久删除，批准前请备份重要资料。报告中的路径仍可能包含个人信息，公开分享前先制作脱敏副本，保留本机原始 Scan JSON 不变。

## 已在使用 Agent：复制下面这段

```text
请使用 https://github.com/LongXL6/windows-360-cleaner，先完整读取 SKILL.md。
确认你能否操作这台 Windows 的终端；能操作时只运行 Scan，不能时指导我双击 scripts\Scan-360.cmd。
解释 Confirmed、ReviewOnly 和保留项后停止，等我明确批准才执行 Remove。不要按名字含 360 批量删除，浏览器资料默认保留。
批准后使用同一份已审阅的原始 Scan 报告；删除后运行 Verify，并按 SKILL.md 输出完整统计和未解决项。
```

## 豆包用户：复制下面整段

豆包支持在对话中上传文件，但不同版本或模式能否直接操作本机 PowerShell 可能不同。下面的提示词要求它先检查自身能力，不能把“给出命令”说成“已经执行”。

```text
请把 https://github.com/LongXL6/windows-360-cleaner 当作一个 AI 技能包使用。
请先读取仓库根目录的 SKILL.md；不要只看 README，也不要根据文件名搜索并强删所有含 360 的内容。
开始前先明确告诉我：你当前是否真的能够读取这个仓库、访问这台 Windows 电脑的本机 PowerShell，并运行命令。
如果可以操作终端，第一步只能运行 Scan。解释 Confirmed、ReviewOnly 和会保留的正常文件后停止，等待我明确批准；未经批准绝对不能运行 Remove。
如果不能操作终端，不要声称已经扫描或删除。请让我下载并完整解压仓库 ZIP，双击 scripts\Scan-360.cmd，保留本机原始 JSON；只向云端提供另做的脱敏副本或节选，并说明节选不能证明完整结果。
只有我审阅本机原始报告并明确批准后，才能指导我双击 Remove-360.cmd，把同一份未修改的原件拖入窗口；不能使用脱敏副本删除。
完成删除后必须运行 Verify；需要向云端提供报告时也先做脱敏副本。按照 SKILL.md 的 Required final output 列出统计，包括零值；缺少原始完整数据时标明未知，不得编造。
```

更详细的两种操作路线、上传报告时的隐私提醒和故障处理见 [豆包与通用 Agent 使用指南](references/doubao.md)。

> [!WARNING]
> 不要使用“搜索所有名字含 `360` 的文件然后强删”这种方法。数字 360 可能出现在照片、游戏地图、模型、哈希值和 Windows 文件中。本技能只处理“**精确允许路径 + 本机产品证据**”同时成立的目标。

## 它解决什么问题

| 找出真正来源 | 保护正常文件 | 给出可核验结果 |
|---|---|---|
| 识别 360 安全产品、浏览器、软件管家、画报/多绘屏保及其下载链 | 普通数字文件、驱动、游戏、系统屏保和浏览器资料默认不动 | 每个动作写入 JSON，最后汇总删除数量、失败项和剩余项 |

## 工作原理

<p align="center">
  <img src="assets/readme/how-it-works.svg" alt="把链接交给 Agent、只扫描、人工确认、删除并验证的四步流程" width="100%">
</p>

核心规则只有一句：**Agent 可以自动扫描和解释，但不能替你批准永久删除。**

## 清理结束会得到什么

<p align="center">
  <img src="assets/readme/cleanup-report.svg" alt="清理结果统计和默认保护内容示例" width="100%">
</p>

Remove 报告中的 `Summary` 会记录：

- 删除的总对象、文件、目录和文件逻辑大小。
- 已删除和仍待 Windows 重启后删除的服务数。
- 已复核删除的计划任务、注册表键和注册表值数量。
- 停止的目标进程，以及跳过、失败、待处理、重试和最终未解决的数量。
- 拒绝访问的路径、ACL 修复尝试/失败数，以及仍未解决的路径数。
- 厂商卸载器的成功、失败和待定数，以及厂商运行后的全局复检是否被安全问题阻断。
- 获批数量、当前仍可处理的交集，以及批准后新增、消失或不再确认的数量。
- 完全删除、部分清理和无法安全测量的路径数量。

文件大小来自删除前后的安全快照差值，并对父子目标去重。硬链接、稀疏文件和压缩文件可能让“文件逻辑大小”与“磁盘实际新增可用空间”不同，所以本项目不会把两者混为一谈。如果 `ImmediateRescanComplete` 为 false，报告中的 Findings 只是最后一份安全的操作前快照，不是剩余状态证明；本次结果必须标记为需要人工关注。重启后的最终结果以 Verify 报告的 `Findings` 为准。

## 为什么它更适合小白

| 防呆保护 | 实际行为 |
|---|---|
| 先扫描后删除 | `Scan` 只读；`Remove` 需要已审阅的 Scan JSON、开关、精确确认短语和管理员授权 |
| 证据不足不强删 | 可疑目标进入 `ReviewOnly`，不会自动升级为可删除项 |
| 拒绝宽泛路径 | 磁盘根目录、Windows、用户目录、整个 Temp 等路径永远不会成为删除目标 |
| 防止目录逃逸 | 目标、父路径或子树出现 junction/符号链接时整批失败关闭 |
| 拒绝访问不冒充成功 | 默认只跳过无法完整检查的精确路径，继续其他已批准目标，并将结果标记为需要处理 |
| 浏览器资料单独保护 | 书签、历史记录和会话默认保留；删除需要第二组明确批准 |
| 不乱杀正常软件 | 普通应用仅仅加载了目标 DLL 时不会被强停，默认要求重启后复查 |
| 不跨系统乱删 | 其他磁盘上的离线 Windows 永远只有扫描模式 |
| 报告不覆盖文件 | JSON 只能新建，拒绝覆盖已有报告或伪装成其他扩展名 |
| 省略独立身份字段 | 默认不填 `ComputerName` / `User`；路径和批准上下文仍可能包含个人信息 |

## 它会检查什么

- 360 安全卫士、杀毒、浏览器、极速浏览器、软件管家等安装目录和卸载记录。
- `dhpingbao`、`duohuipingbao`、`huabao_tmp`、`360hb_tmp` 等画报/屏保组件。
- `SoftMgrUpdate*` 计划任务和有证据支持的第三方工具箱下载链。
- 指向已确认目标的启动项、服务和正在运行的进程。
- Explorer 加载的 `qcnethelp64.dll`、`xhqcnethelp64.dll`、`SoftMgrExt64.dll` 等锁定模块。
- 用户指定的其他 Windows 磁盘；这些结果始终只报告、不跨系统删除。

## 它默认不会删除什么

- 仅仅名字中含有数字 `360` 的文件或文件夹。
- Windows 自带屏保，例如 `Bubbles.scr`、`PhotoScreensaver.scr`、`scrnsave.scr`。
- 驱动精灵、显卡/网卡驱动、游戏目录和 Steam/iRacing 数字资源。
- `winToolBox` 中独立的 `kantu`、`clear`、`pdf`、`zip` 工具；本工具没有删除这些独立组件的开关。
- `360se6\User Data`、`360Chrome\Chrome\User Data`、`360ChromeX\Chrome\User Data` 和旧版 `360browser` 中的浏览器个人资料；程序目录会单独检测。
- 其他 Windows 安装中的任何文件。

## 安装为 Codex Skill

将整个仓库复制到：

```text
%USERPROFILE%\.codex\skills\windows-360-cleaner
```

然后在 Codex 中说：

```text
$windows-360-cleaner 帮我先扫描这台电脑上的 360 全家桶，不要直接删除。
```

Agent 应先读取 [SKILL.md](SKILL.md)。只有需要判断检测证据时才读取 [检测目录](references/detection-catalog.md)，遇到锁文件时才读取 [疑难排查](references/troubleshooting.md)。

豆包和其他不支持 `$skill-name` 安装方式的 Agent 不需要修改技能名称：直接给它仓库链接，并要求先读取 `SKILL.md`。如果 Agent 无法运行本机命令，使用上面的手动 Scan 路线。

<details>
<summary><strong>不使用 Agent：双击脚本的备用方法</strong></summary>

### 1. 先扫描

1. 点击 GitHub 页面右上角绿色的 **Code**。
2. 点击 **Download ZIP** 并解压。
3. 双击 `scripts\Scan-360.cmd`。
4. 按窗口实际显示的 `Report:` 路径找到 JSON 报告（通常在桌面），查看扫描结果。

扫描不会删除任何东西，也不需要管理员权限。

### 2. 确认后删除

1. 关闭正在运行的 360 软件和浏览器。
2. 双击 `scripts\Remove-360.cmd`。
3. 阅读警告并按 `Y`。
4. 再输入 `REMOVE-360`。
5. 把刚才已审阅的 Scan JSON 拖入窗口，按回车。
6. Windows 弹出管理员授权窗口时点击“是”。
7. 在原窗口查看删除动作、汇总和剩余项，完成后重启 Windows 一次。

删除是永久操作，不会进入回收站。Scan JSON 是精确批准清单：提权后新出现但未在报告中获批的目标只会报告，不会删除。输入错误、直接回车或按 `N` 都会安全退出并返回非成功状态。

### 3. 重启后验证

双击 `scripts\Verify-360.cmd`。如果没有 `Confirmed`，说明已确认的组件没有重新出现。

</details>

<details>
<summary><strong>PowerShell 命令和高级选项</strong></summary>

```powershell
# 只扫描
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan

# 删除已确认目标：需要已审阅的 Scan 报告、管理员权限、开关和精确确认短语
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ApprovedReport 'C:\path\to\approved-scan.json' `
  -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360

# 高风险可选项：先用同一选项生成 Scan 报告，备份并单独审阅浏览器资料
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -IncludeBrowserProfiles

# 再使用上一步实际生成且已审阅的报告执行删除
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ApprovedReport 'C:\path\to\approved-scan.json' `
  -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 `
  -IncludeBrowserProfiles -BrowserProfileConfirmation DELETE-360-BROWSER-DATA

# 删除后验证
.\scripts\Invoke-360Cleanup.ps1 -Mode Verify

# 扫描另一块磁盘上的 Windows，绝不自动删除
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -OfflineWindowsRoot F:\
```

`-AllowExplorerRestart` 和 `-ForceLockedTargets` 是高级故障处理选项，不在小白流程中启用。Agent 必须先解释精确目标和风险，再重新获得批准。对 `AccessDenied` 路径，`-ForceLockedTargets` 只在其他动作结束后修复已验证的精确路径 ACL，然后从已批准根路径重新扫描；一旦出现重解析点或未知检查错误就不会删除。

</details>

<details>
<summary><strong>WinToolBox 是谁家的，为什么会与 360 组件一起出现</strong></summary>

`WinToolBox` 不是微软或 Windows 官方软件，也不是 360 官方产品。我们在真实机器上确认其主程序、看图、清理和 PDF 组件由 **北京奥蓝德信息科技有限公司**签名；服务名带有 `huajun`，与华军软件园体系相符。

同一个工具箱目录可能混入由**北京奇虎科技有限公司**签名的 `KitTip.dll`、`cssdk.dll`，后者产品信息为 `360.cn / 统计组件`。我们还遇到过其 `SoftMgr` 子目录包含 360 安全卫士组件并参与下载多绘屏保。

因此本项目将它描述为：**奥蓝德/华军系第三方工具箱；当本机存在奇虎签名 DLL、360 SoftMgr、自动下载任务或多绘屏保链路时，按 PUP/捆绑推广载体处理，而不是误称为 360 官方 WinToolBox。**

数字签名只能证明发布者身份，不代表软件行为一定符合用户意愿。公开入口：[奥蓝德](https://www.softbutler.cn/) · [华军软件园](https://www.onlinedown.net/contact.html)

</details>

<details>
<summary><strong>为什么多绘屏保会“删了又回来”</strong></summary>

我们遇到过的真实链路是：

```text
奥蓝德/华军系 winToolBox 更新服务
  → 含 360 组件的 SoftMgrUpdate* 计划任务
  → Temp\duohuipingbao\360hb_tmp\huabaosetup.exe
  → AppData\Local\dhpingbao\duohuipingbao.exe
  → Explorer 加载 qcnethelp / SoftMgrExt DLL
```

如果只删除最终屏保目录，不删除有证据支持的下载服务和更新任务，它就可能重新出现。本技能会先找下载来源，再处理持久化，最后验证；普通软件仅仅加载了目标 DLL 时不会被强停。

如果已确认的 `%LOCALAPPDATA%\dhpingbao` 包含符合证据的 `huabaosetup.exe`，Scan 会把它的精确路径和 SHA-256 单独列入批准清单。因为这是用户可写目录中的可执行文件，它还必须具有有效 Authenticode 签名，且签名者简称精确为 `Beijing Qihu Technology Co., Ltd.`；其他情况只会标记为 `ReviewOnly`。Remove 会在启动前再次验证签名、哈希和路径，并且只使用内置的 `/uninstall:byUserName` 参数，不会盲目执行注册表中的命令行。服务、任务和注册表对象的稳定身份指纹也是 Scan 批准身份的一部分；任何同名替换或之后的内容变化都会被跳过，并要求重新扫描批准。

</details>

## 验证技能包本身

下面的测试只会在系统临时目录创建并删除隔离夹具，不会对真实 360 软件执行 Remove：

```powershell
.\scripts\Test-360Cleaner.ps1
```

它会验证：

- PowerShell 5.1 编码和语法。
- 报告防覆盖、双重确认与取消退出码。
- 普通 `360` 用户文件、浏览器书签和 WinToolBox 保留目录不受影响。
- 伪造 marker、junction 外部 canary、锁文件和离线 Windows 失败关闭。
- 重复运行归零、嵌套目标不重复统计、目标数量上限和 JSON Summary。

GitHub Actions 在每次提交后运行同一套测试。

## 技能包结构

```text
windows-360-cleaner/
├── SKILL.md                    # Agent 的入口与安全规则
├── agents/openai.yaml          # Codex 展示信息
├── scripts/                    # Scan / Remove / Verify 与隔离测试
├── references/                 # 新手指南、检测证据、推广文案和发布维护
├── docs/                       # 待发布的中英文静态介绍页
├── assets/readme/              # README 原创教学图片与微信二维码
├── README.en.md                # English guide
└── README.md                   # 中文默认首页
```

## 分享与维护

准备介绍给朋友或发布到社交平台？从 [小红书 / X / 微信 / 抖音文案包](references/social-sharing.md) 选择一段修改即可；首次行动统一为“先扫描”。

维护者可按 [网站发布与搜索发现指南](references/publishing.md) 预览 `docs/`，审阅后再开启 GitHub Pages、设置仓库介绍和提交 sitemap。页面文件已经备好，不代表网站已发布或 Google 已收录。

## 安全说明

- 重要电脑建议先建立系统还原点并备份浏览器资料。
- 不要从不可信转载站下载修改版脚本。
- 本项目无法保证覆盖每个历史版本、地区版本或未来变体。
- 正常软件若进入 `ReviewOnly`，不要手工强删；请提交 Issue，并附脱敏后的路径、文件版本和签名信息。
- “PUP/潜在不受欢迎软件”是行为与用户同意层面的分类，不等于在法律上宣称其为病毒或木马。

## 联系作者

遇到无法判断的 `ReviewOnly` 项目，优先提交公开的 [GitHub Issue](https://github.com/LongXL6/windows-360-cleaner/issues)，这样解决方案也能帮助其他用户。需要通过微信联系作者时，可以点击或扫描下面的二维码。

<p align="center">
  <a href="assets/readme/wechat-longxl.jpg">
    <img src="assets/readme/wechat-longxl.jpg" alt="微信联系 LONG XL 的二维码" width="260">
  </a>
</p>

> [!NOTE]
> 微信是个人联系渠道，不提供付费远程控制，也不要向任何人发送密码、验证码或未脱敏的私人文件。项目问题仍建议优先使用 GitHub Issue。

## License

[MIT](LICENSE)
