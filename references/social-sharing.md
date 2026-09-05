# 社交平台分享文案（可编辑草稿）

> 这是供项目维护者手动修改和发布的草稿，不代表已在任何社交平台发布。项目本身不会为这些模板增加自动发布、网络上报或遥测。

## 发布时统一的事实边界

- Windows 360 Cleaner 是一个给 AI Agent 使用的开源 Skill 技能包，不是一键清理软件，也不是杀毒软件。
- 统一流程是：`Scan → 解释 Confirmed / ReviewOnly / 保留项 → 用户明确批准 → Remove → 重启后 Verify`。
- `Scan` 只读；`ReviewOnly` 不会自动删除；浏览器个人资料默认保留。
- `Remove` 是永久操作，需要已审阅的 Scan JSON、明确确认和管理员授权。
- 结果报告记录删除、跳过、失败、待处理和剩余项。其中的文件逻辑大小不等于磁盘真实新增可用空间。
- 不声称“一键清干净”、“保证安全”、“保证不误删”或“真实释放 XX GB”；不虚构使用前后对比。
- 不暗示发布者自己安装过某个产品。如引用案例，要明确写成“项目文档记录的已观察链路”，不扩大到所有电脑。

## 统一链接

- 仓库：https://github.com/LongXL6/windows-360-cleaner
- 中文新手指南：https://github.com/LongXL6/windows-360-cleaner/blob/main/references/getting-started.md
- English beginner guide: https://github.com/LongXL6/windows-360-cleaner/blob/main/references/getting-started.en.md

> 新手指南随同一个 PR 准备时，在合并前链接可能暂时返回 404。发布前必须用无登录窗口重新打开。当前没有启用项目网站，CTA 应直达 GitHub。

## 画面素材与通用编辑建议

现有原创素材可复用：

- `assets/readme/windows-360-cleaner-hero.jpg`：首图或封面。
- `assets/readme/how-it-works.svg`：展示 Scan、批准、Remove、Verify 的流程。
- `assets/readme/cleanup-report.svg`：解释结果报告与默认保留项。图中数字仅为输出格式示例，不代表真实电脑或预期清理效果，发布时保留“示例”标记。
- `assets/readme/wechat-longxl.jpg`：仅在维护者确认愿意公开个人微信联系方式时使用；项目问题仍优先引导 GitHub Issue。

竖屏裁切、封面字号、字幕安全区、时长和标签数都只是编辑建议，不是各平台的官方硬性规则。发布前应查看当时的平台帮助与预览效果。

## 小红书图文草稿

### 标题候选

1. 别再搜 `*360*` 强删了：先扫描，再决定
2. Windows 里的 360 组件怎么审计？给小白的 5 步流程
3. 一个不代替你点“删除”的 AI 清理 Skill

### 正文

Windows 里的数字 `360` 可能出现在软件、游戏资源、全景照片或哈希中，所以“搜名字后全删”很容易伤到无关文件。

没有安装 Agent 也可以开始：下载并完整解压 ZIP，双击 `scripts\Scan-360.cmd`，先得到只读扫描报告，再自己阅读或让 Agent 帮忙解释。

Windows 360 Cleaner 是一个给 AI Agent 使用的开源 Skill。它先运行只读 Scan，再把结果分成 `Confirmed`、`ReviewOnly` 和默认保留项。Agent 可以帮你解释，但不能代替你批准永久删除。

完整流程是：

1. Scan 只读扫描。
2. 解释证据、可疑项和保留项。
3. 用户看完报告后明确批准。
4. Remove 只处理“已批准且仍然 Confirmed”的目标。
5. 重启 Windows 后用 Verify 再检查。

它不是杀毒软件，不保证覆盖所有历史或未来版本。浏览器书签、历史和会话等个人资料默认保留。

仓库：https://github.com/LongXL6/windows-360-cleaner

新手指南：https://github.com/LongXL6/windows-360-cleaner/blob/main/references/getting-started.md

可选标签：`#Windows` `#开源工具` `#AI技能` `#PowerShell` `#电脑使用技巧`

## X 英文短帖

> Windows 360 Cleaner is an open-source AI-agent skill, not a one-click antivirus. Flow: Scan → explain → approve → Remove → Verify. Ambiguous findings stay review-only; browser profiles are preserved by default. https://github.com/LongXL6/windows-360-cleaner

发布前应再用当时的 X 编辑器检查字符计数和链接预览；上面草稿的纯文本长度不超过 280 字符。

## 微信朋友圈草稿

整理了一个开源 Windows 360 Cleaner Skill。可以让有本机终端权限的 Agent 先 Scan，也可以自己下载并完整解压 ZIP、双击 Scan-360.cmd。先读报告、看懂 Confirmed 和 ReviewOnly，明确批准后才 Remove，最后重启并 Verify。浏览器个人资料默认保留；没有 Agent 也能从扫描开始。

仓库：https://github.com/LongXL6/windows-360-cleaner

新手指南：https://github.com/LongXL6/windows-360-cleaner/blob/main/references/getting-started.md

## 微信公众号短稿

### 标题

别再按文件名强删：一个先扫描、再批准的 Windows 360 审计 Skill

### 摘要

Windows 360 Cleaner 把“发现”、“决定”和“验证”分开，避免把名称中的数字 `360` 当成删除授权。

### 正文

直接搜索并强删所有名称含 `360` 的文件，会把正常软件、游戏资源、全景媒体和 Windows 文件一起卷进来。这个项目使用精确路径、产品证据和持久化动作来分类所见内容。

它是 AI Agent 的 Skill 技能包，而不是一键杀毒工具。第一步始终是只读 Scan：Agent 解释 `Confirmed`、`ReviewOnly` 和默认保留项，然后停下等待用户批准。只有“已在 Scan 报告中批准且当下仍然 Confirmed”的目标才能进入 Remove。

Remove 会输出 JSON 账单，记录已删除、跳过、失败、待处理和无法安全测量的项。文件逻辑大小不等于磁盘实际新增可用空间。服务或 Explorer 扩展可能需要重启 Windows，最终状态要以重启后的 Verify 为准。

项目默认保留浏览器书签、历史和会话等个人资料，也不把驱动、游戏目录或全景照片当成目标。它无法保证覆盖所有历史、地区或未来变体，所以证据不足的项目应留在 `ReviewOnly`。

查看仓库：https://github.com/LongXL6/windows-360-cleaner

从新手流程开始：https://github.com/LongXL6/windows-360-cleaner/blob/main/references/getting-started.md

## 抖音 30–45 秒分镜草稿

| 时间 | 画面建议 | 口播 | 屏幕字幕 |
|---|---|---|---|
| 0–4 秒 | 展示文件名里同时出现正常数字 `360` 与软件名；不展示真实个人路径 | “电脑里搜到 360，真的能全删吗？” | 别把文件名当成删除授权 |
| 4–10 秒 | 切到 `windows-360-cleaner-hero.jpg` 或仓库首页 | “Windows 360 Cleaner 是给 AI Agent 用的开源 Skill，不是杀毒软件。” | AI Agent Skill · 不是一键杀毒 |
| 10–18 秒 | 展示 `how-it-works.svg` | “它先只读 Scan，把 Confirmed、ReviewOnly 和保留项解释清楚。” | Scan 只读 → 结果分级 |
| 18–27 秒 | 演示“停下等待批准”，不播放未经同意的真实删除 | “Agent 可以解释，但不能代替你批准永久删除。” | 用户明确批准后才 Remove |
| 27–36 秒 | 展示 `cleanup-report.svg` 并保留“示例”标记，或展示脱敏隔离测试报告 | “处理后会记录删除、跳过、失败和待处理项；这里的数字只是示例。” | 报告示例，非实测效果 |
| 36–45 秒 | 展示 Verify 流程和 GitHub 仓库链接 | “最后重启 Windows 再 Verify。想看完整流程，去 GitHub 新手指南。” | 重启后 Verify · GitHub 搜 Windows 360 Cleaner |

### 结尾 CTA

“先看新手指南，第一步只做 Scan。链接在简介或置顶评论。”

如果需要录制真实 Windows 界面，只使用经所有者知情同意的测试机或隔离夹具，不要展示真实删除效果来制造夸张的“前后对比”。

## 发布前检查

- [ ] 手动打开仓库、中文指南和英文指南的最终链接，确认已合并、无 404，且不需要仓库权限。
- [ ] 删除或遮挡电脑名、用户名、真实路径、已安装软件清单、任务名、报告详情、通知、联系方式和二维码等非必要信息。
- [ ] 真人声音、真实机器画面、案例数据和个人联系方式已获得相关人的知情同意。
- [ ] 确认文案没有暗示发布者安装过某个产品，也没有虚构“亲测”、数量、速度、磁盘空间或清理成功率。
- [ ] 明确说明这是 AI Agent Skill，删除需要人工批准，不是一键杀毒或保证安全的工具。
- [ ] 若展示 JSON 报告，已用虚构夹具或完整脱敏副本；原始报告不上传到公开平台。
- [ ] 使用个人微信二维码前已再次确认公开意愿；不诱导用户发送密码、验证码或未脱敏私人文件。
- [ ] 根据当前平台帮助检查字数、封面、链接、标签和音频规则；本文的画面建议不当作官方规范。
