# 界面截图（示例数据）

这些截图由 `tools/New-UiScreenshots.ps1` 生成，工具版本 1.0.0。02–07 使用示例数据，每张图顶部都有“示例数据截图”横幅；01 是真实的资源管理器文件列表，只显示打包后的文件，不含任何检查数据。
数据来自在隔离的临时示例目录上运行的检查逻辑（不会删除任何东西）；显示路径已替换为 `C:\Users\示例用户`。生成过程没有检查或删除这台电脑上的真实软件，也没有弹出 Windows 的权限窗口。

| 文件 | 内容 |
|---|---|
| `01-start-entry.png` | 解压后的文件夹：双击“开始检查”（真实的资源管理器文件列表，只截取文件列表区域；没有运行任何清理） |
| `02-scan-progress.png` | 检查进行中：只显示当前这一步和已用时间；检查不会删除任何东西，可以随时点“停止检查” |
| `03-scan-results.png` | 检查结果：按软件分组，每一行只回答“删不删”；打开时一个都不勾选（图中演示了只勾选 360 画报 / 多绘屏保，360 安全浏览器没有勾选、会保留）；下方说明区解释当前这一行，删除后会怎样 |
| `04-confirm-delete.png` | 删除前确认：列出要删除的内容、删除后会怎样和会保留的内容（360 安全浏览器没选，会保留）；默认按钮是“取消”，要点红色的“删除”才会删除 |
| `05-cleanup-result.png` | 删除结果：大标题说明删掉了没有，下面一行告诉你接下来怎么做；统计数字和操作记录放在“详细信息”里 |
| `06-home-after-restart.png` | 重启后再次打开：找到上次删除的记录，点“检查上次删除的结果”确认删干净了（检查不会删除任何东西） |
| `07-verify-result.png` | 检查上次删除的结果：多绘屏保已删掉，360 安全浏览器按你的选择保留着，不算删除失败 |

Screenshots use sample data. They were produced from an isolated temporary fixture with read-only detection and verification logic; nothing on a real PC was scanned or removed.
