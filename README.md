# Windows 360 Cleaner Skill（技能包）

这是一个让 AI Agent/Codex 读取并执行的开源 **Skill 技能包**，不是需要用户学习操作的独立清理软件。`scripts` 里的 PowerShell 只是技能包调用的确定性执行资源，用于安全扫描和删除已经确认的 360/Qihoo 软件、360 安全浏览器、360 软件管家下载组件、360 画报/多绘屏保及其持久化残留。

## 30 秒快捷使用（直接复制下面这整段）

把下面整段原样发给能够读取 GitHub 的 Agent：

```text
请把 https://github.com/LongXL6/windows-360-cleaner 当作一个 Skill 技能包使用，而不是普通清理工具。
请先完整读取仓库根目录的 SKILL.md，并遵守其中所有安全边界；需要判断可疑目标时再读取 references。
第一步只运行 Scan，不要删除，向我分别解释 Confirmed、ReviewOnly、会保留的正常文件和浏览器资料。
只有在我看完扫描结果并明确批准后，才能执行 Remove；不要扩大允许路径，不要跨离线 Windows 系统删除。
删除后先读取 Remove JSON 报告中的 Summary；然后运行 Verify，并从 Verify JSON 报告的 Findings 统计最终剩余的 Confirmed 数。
最终请清楚输出：总共删除的对象数、文件数、目录数、清除文件的逻辑大小（字节和易读单位）、服务已删除/待重启删除数、计划任务数、注册表键/值数、停止的进程数、跳过/失败/待处理数、重试次数、未解决目标数、Verify 后剩余 Confirmed 数；即使某项为 0 也要写出来。如果路径统计不完整，必须说明这里只是最低确认值。不要把文件逻辑大小误称为实际释放的磁盘空间。
```

> 这不是“看到文件名里有 360 就全部删除”的脚本。数字 360 可能出现在游戏地图、全景图片、模型、哈希值和 Windows 文件中，粗暴删除很容易误伤系统或个人数据。

## 不使用 Agent 时的备用方法

### 第一步：先扫描

1. 点击 GitHub 页面右上角绿色的 **Code**。
2. 点击 **Download ZIP**。
3. 解压下载的 ZIP。
4. 双击 `scripts\Scan-360.cmd`。
5. 查看桌面生成的 JSON 报告和窗口里的扫描结果。

扫描不会删除任何东西，也不需要管理员权限。

### 第二步：确认后删除

1. 关闭正在运行的 360 软件和浏览器。
2. 双击 `scripts\Remove-360.cmd`。
3. 阅读警告，按 `Y` 确认。
4. 再输入 `REMOVE-360`；输入错误、直接回车或按 `N` 都会安全退出并返回非成功状态。
5. Windows 弹出管理员授权窗口时点击“是”。
6. 完成后重启电脑一次。

删除是永久操作，不会进入回收站。脚本只自动删除“精确允许路径 + 本机产品证据”同时成立的目标；可疑但证据不足的项目只会写入报告。浏览器书签、历史记录和用户配置默认保留。

### 第三步：验证

重启后双击 `scripts\Verify-360.cmd`。如果没有 `Confirmed` 项目，说明已确认的 360 组件没有重新出现。

## Agent 执行入口

Agent 必须先读取 [SKILL.md](SKILL.md)，需要判断或扩展检测时再读取 [检测目录](references/detection-catalog.md)，遇到锁文件时再读取 [疑难排查](references/troubleshooting.md)。不要让 Agent 一开始加载所有参考资料，也不要绕过扫描、授权和验证步骤。

## 安装为 Codex Skill

将整个仓库复制到：

```text
%USERPROFILE%\.codex\skills\windows-360-cleaner
```

然后在 Codex 中使用：

```text
$windows-360-cleaner 帮我先扫描这台电脑上的 360 全家桶，不要直接删除。
```

## 删除完成后会输出什么

终端和 JSON 报告的 `Summary` 会同时给出以下可核验统计：

- 删除的总对象、文件、目录和文件逻辑字节数（另附 KB/MB/GB 易读值）。逻辑大小不冒充实际磁盘释放量，因为硬链接、稀疏文件和压缩文件可能让两者不同。
- 已删除和仍待 Windows 重启后删除的服务数，以及已复核删除的计划任务、注册表键和注册表值数量。
- 为清理而停止的目标进程数量，以及跳过、失败、待处理、重试和最终未解决的数量。
- 完全删除及部分清理的目标数、立即复扫是否仍有 `Confirmed`；这不代表所有动作均成功，重启后的最终结果仍从 Verify 报告的 `Findings` 读取。
- `PathAccountingComplete`：若为 `false`，说明某个路径因安全校验而无法测量，显示的总量只是“至少已确认删除”的数量，不会假装统计完整。

文件、目录和字节数来自删除前后的安全快照差值；父子目标会先去重，因此不会因为同一目录被重复列出而重复计数。完整逐项动作仍保留在报告的 `Actions` 中，方便 Agent 或用户复查。

## 它会检查什么

- 360 安全卫士、杀毒、浏览器、极速浏览器、软件管家等安装目录和卸载记录。
- `dhpingbao`、`duohuipingbao`、`huabao_tmp`、`360hb_tmp` 等画报/屏保组件。
- `SoftMgrUpdate*` 计划任务和有证据支持的第三方工具箱下载链。
- 指向已确认目标的启动项、服务和正在运行的进程。
- Explorer 加载的 `qcnethelp64.dll`、`xhqcnethelp64.dll`、`SoftMgrExt64.dll` 等导致强删失败的模块。
- 用户指定的其他 Windows 磁盘；默认只扫描，不跨系统删除。

## 防呆与正常文件保护

- JSON 报告只能新建，拒绝覆盖任何已有文件，也拒绝把报告写成 `.docx`、`.jpg` 等其他扩展名。
- 删除目标必须位于内置的精确路径允许表中；用户文档、下载、照片、Windows 目录、磁盘根目录和宽泛临时目录会被拒绝。
- 所有路径先整体预检；任何一个路径不安全时，服务、任务、注册表、进程和文件都不会开始修改。
- 目标本身、父路径或内部任意子目录出现 junction、符号链接等重解析点时，删除会失败关闭，防止跳到目录外。
- `Program Files\360` 等名称不再单独构成删除证据；还必须找到 360/Qihoo 产品元数据或有效数字签名。
- 仅有 `360Base.dll` 等空文件名不能冒充 SoftMgr 证据。
- 默认不强停加载 DLL 的普通程序，不自动修改文件所有权/ACL；锁定目标会保留到重启后复查。
- 默认报告不记录电脑名和 Windows 用户名，便于脱敏分享。

## WinToolBox 到底是谁家的

`WinToolBox` 不是微软或 Windows 官方软件，也不是 360 官方产品。我们在真实机器上确认其主程序、看图、清理和 PDF 组件由 **北京奥蓝德信息科技有限公司**签名；服务名还带有 `huajun`，与华军软件园体系相符。

但同一个工具箱目录可能混入由**北京奇虎科技有限公司**签名的 `KitTip.dll`、`cssdk.dll`，后者产品信息为 `360.cn / 统计组件`；我们还遇到过其 `SoftMgr` 子目录包含 360 安全卫士组件并参与下载多绘屏保。因此本项目将它描述为：

> 奥蓝德/华军系第三方工具箱；当存在奇虎签名 DLL、360 SoftMgr、自动下载任务或多绘屏保链路时，按 PUP/捆绑推广载体处理，而不是误称为 360 官方 WinToolBox。

数字签名只能证明发布者身份，不代表软件行为一定符合用户意愿。相关公开入口：[奥蓝德](https://www.softbutler.cn/)、[华军软件园](https://www.onlinedown.net/contact.html)。

## 它不会自动删除什么

- 仅仅名字中含有数字 `360` 的文件或文件夹。
- Windows 自带屏保，例如 `Bubbles.scr`、`PhotoScreensaver.scr`、`scrnsave.scr`。
- 驱动精灵、显卡/网卡驱动、游戏目录和 Steam/iRacing 数字资源目录。
- `winToolBox` 中独立的 `kantu`、`clear`、`pdf`、`zip` 工具，除非用户明确要求连这些工具一起删除。
- `360Chrome`、`360se6`、`360browser` 中的浏览器个人资料；删除书签和历史记录需要单独的双重确认参数。
- 其他 Windows 安装中的文件；本仓库提供的脚本对离线系统始终只有扫描模式，没有跨系统删除开关。

## PowerShell 用法

```powershell
# 只扫描
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan

# 删除已确认目标（需要管理员权限、开关和精确确认短语）
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360

# 高风险可选项：删除浏览器个人资料，必须先备份并单独批准
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ConfirmRemoval -ConfirmationPhrase REMOVE-CONFIRMED-360 `
  -IncludeBrowserProfiles -BrowserProfileConfirmation DELETE-360-BROWSER-DATA

# 删除后验证
.\scripts\Invoke-360Cleanup.ps1 -Mode Verify

# 扫描另一块磁盘上的 Windows，绝不自动删除
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -OfflineWindowsRoot F:\
```

## 先验证工具本身

运行下面的命令只会在系统临时目录创建并删除隔离夹具，不会对真实 360 软件执行删除：

```powershell
.\scripts\Test-360Cleaner.ps1
```

它会验证报告防覆盖、确认短语、取消退出码、普通 `360` 用户文件、浏览器书签、WinToolBox 保留目录、伪造 marker、重解析点外部 canary、锁文件、重复运行、目标数量上限和离线系统扫描。GitHub Actions 也会在每次提交时运行同一套测试。

## 为什么多绘屏保会“删了又回来”

我们遇到过的真实链路是：第三方工具箱后台更新服务启动含 360 组件的软件管家任务，任务在临时目录生成 `huabaosetup.exe` 和 `360hb_tmp`，随后安装到 `AppData\Local\dhpingbao`。多绘屏保与软件管家的 DLL 还会被 Explorer 加载，因此普通删除会报“拒绝访问”。如果只删最终目录、不删有证据支持的下载服务和更新任务，它就可能再次出现。

本项目把经验固化成可审计流程：先找下载源，再停服务和任务，然后只结束“可执行文件本身位于确认目录”的进程。普通软件仅仅加载了目标 DLL 时不会被强停；默认保留锁定目标，重启后再验证。

## 安全说明

- 请先扫描并阅读结果；重要电脑建议先建立系统还原点。
- `-AllowExplorerRestart` 和 `-ForceLockedTargets` 是高级故障处理选项，不在小白一键删除中启用；使用前必须再次解释并获得批准。
- 不要从不可信的转载站下载修改版脚本。
- 本项目无法保证覆盖每个历史版本或地区版本。
- 如果正常软件被列为 `ReviewOnly`，不要手工强删；请提交 Issue，并附上脱敏后的路径、文件版本和签名信息。
- “PUP/潜在不受欢迎软件”是行为和用户同意层面的分类，不等于在法律上宣称其为病毒或木马。

## 许可证

[MIT](LICENSE)
