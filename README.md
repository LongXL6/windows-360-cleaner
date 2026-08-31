# Windows 360 Cleaner Skill

一个面向普通 Windows 用户和 AI Agent 的开源清理工具，用于扫描并删除已经确认的 360/Qihoo 软件、360 安全浏览器、360 软件管家下载组件、360 画报/多绘屏保，以及相关服务、计划任务、启动项和卸载残留。

> 这不是“看到文件名里有 360 就全部删除”的脚本。数字 360 可能出现在游戏地图、全景图片、模型、哈希值和 Windows 文件中，粗暴删除很容易误伤系统或个人数据。

## 最简单的使用方法

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
4. Windows 弹出管理员授权窗口时点击“是”。
5. 完成后重启电脑一次。

删除是永久操作，不会进入回收站。脚本只自动删除带有确定证据的目标；可疑但证据不足的项目只会写入报告。

### 第三步：验证

重启后双击 `scripts\Verify-360.cmd`。如果没有 `Confirmed` 项目，说明已确认的 360 组件没有重新出现。

## 直接交给 AI Agent

把仓库链接发给支持读取 GitHub 的 Agent，然后说：

> 请完整阅读仓库根目录的 `SKILL.md`，先只扫描我的 Windows 电脑，解释所有 Confirmed 和 ReviewOnly 项目；得到我确认后再清理，并在最后验证。

Agent 应先读取 [SKILL.md](SKILL.md)，需要扩展检测时再读取 [检测目录](references/detection-catalog.md) 和 [疑难排查](references/troubleshooting.md)。

## 安装为 Codex Skill

将整个仓库复制到：

```text
%USERPROFILE%\.codex\skills\windows-360-cleaner
```

然后在 Codex 中使用：

```text
$windows-360-cleaner 帮我先扫描这台电脑上的 360 全家桶，不要直接删除。
```

## 它会检查什么

- 360 安全卫士、杀毒、浏览器、极速浏览器、软件管家等安装目录和卸载记录。
- `dhpingbao`、`duohuipingbao`、`huabao_tmp`、`360hb_tmp` 等画报/屏保组件。
- `SoftMgrUpdate*` 计划任务和有证据支持的第三方工具箱下载链。
- 指向已确认目标的启动项、服务和正在运行的进程。
- Explorer 加载的 `qcnethelp64.dll`、`xhqcnethelp64.dll`、`SoftMgrExt64.dll` 等导致强删失败的模块。
- 用户指定的其他 Windows 磁盘；默认只扫描，不跨系统删除。

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
- 其他 Windows 安装中的文件，除非用户明确指定离线系统并再次批准。

## PowerShell 用法

```powershell
# 只扫描
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan

# 删除已确认目标（需要管理员权限和明确开关）
.\scripts\Invoke-360Cleanup.ps1 -Mode Remove -ConfirmRemoval

# 删除后验证
.\scripts\Invoke-360Cleanup.ps1 -Mode Verify

# 扫描另一块磁盘上的 Windows，绝不自动删除
.\scripts\Invoke-360Cleanup.ps1 -Mode Scan -OfflineWindowsRoot F:\
```

## 为什么多绘屏保会“删了又回来”

我们遇到过的真实链路是：第三方工具箱后台更新服务启动含 360 组件的软件管家任务，任务在临时目录生成 `huabaosetup.exe` 和 `360hb_tmp`，随后安装到 `AppData\Local\dhpingbao`。多绘屏保与软件管家的 DLL 还会被 Explorer 加载，因此普通删除会报“拒绝访问”。如果只删最终目录、不删有证据支持的下载服务和更新任务，它就可能再次出现。

本项目把经验固化成可审计流程：先找下载源，再停服务和任务，然后按精确路径结束进程、释放 DLL 锁、删除目标，最后重新扫描。

## 安全说明

- 请先扫描并阅读结果；重要电脑建议先建立系统还原点。
- 不要从不可信的转载站下载修改版脚本。
- 本项目无法保证覆盖每个历史版本或地区版本。
- 如果正常软件被列为 `ReviewOnly`，不要手工强删；请提交 Issue，并附上脱敏后的路径、文件版本和签名信息。
- “PUP/潜在不受欢迎软件”是行为和用户同意层面的分类，不等于在法律上宣称其为病毒或木马。

## 许可证

[MIT](LICENSE)

