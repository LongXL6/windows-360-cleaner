# 网站发布、版本发布与日常维护

[返回首页](../README.md) · [社交文案包](social-sharing.md)

项目网站已于 2026-09-05 通过 GitHub Pages 发布：[中文](https://longxl6.github.io/windows-360-cleaner/) · [English](https://longxl6.github.io/windows-360-cleaner/en/)。发布源为 `main` 的 `/docs`，HTTPS 已开启，仓库 About 的网站、description 和 topics 已设置。当前状态应以 Pages 设置、部署运行和公开页面为准；上线不等于 Google 已收录。

带版本号的下载包（例如 `windows-360-cleaner-v1.0.0.zip`）由维护者在本机构建，再手动附加到 GitHub Releases，步骤见 [发布版本 ZIP](#发布版本-zip)。Release 真正发布之前，README 和网站继续使用 main 分支 ZIP 链接，不要写“已发布”。

## 修改什么文件

| 想改的内容 | 文件 |
|---|---|
| GitHub 首页与下载入口 | `README.md`、`README.en.md` |
| 新手步骤、结果解释与常见问题 | `references/getting-started.md`、`references/getting-started.en.md` |
| 豆包等不能运行本机命令的 Agent 的用法 | `references/doubao.md` |
| Agent 怎么跟用户说话（安全规则、建议规则、确认步骤） | `SKILL.md`、`agents/openai.yaml`（默认提示词） |
| 窗口和 Agent 说的大白话文字 | `scripts/Windows360Cleaner.Library.ps1`（共用文字表和确认文字）、`scripts/Select-360Cleanup.ps1`（只在窗口里用的 `Gui.*`）、`scripts/Show-360Summary.ps1`（只给 Agent 用的 `Agent.*`）。改完运行全部测试：主界面和 Agent 文字有禁用词检查，README、指南、网站和 `使用说明.txt` 里引用的按钮名、标题也要一起改 |
| 各平台标题、正文、口播和素材安排 | `references/social-sharing.md` |
| 网站中文与英文正文、分享卡片文案 | `docs/index.html`、`docs/en/index.html` |
| 字体、颜色、间距和手机排版 | `docs/styles.css` |
| 正式页面地址列表 | `docs/sitemap.xml` |
| 版本号与更新日志 | `VERSION`、`CHANGELOG.md`、`scripts/Invoke-360Cleanup.ps1`（`$script:ToolVersion`）、`scripts/Windows360Cleaner.Library.ps1`（`$script:W360ToolVersion`） |
| 发布包里的 `使用说明.txt` | `packaging/使用说明.txt`（模板，版本号写成 `{{VERSION}}` 占位） |
| 文档截图（示例数据） | 用 `tools/New-UiScreenshots.ps1` 重新生成到 `assets/screenshots/` |
| 求助 Issue 表单 | `.github/ISSUE_TEMPLATE/help.yml`（不要改文件名：“获取帮助”窗口里的“打开求助网页”按钮固定打开 `issues/new?template=help.yml`） |

网站无需构建、JavaScript、账号或第三方统计。修改文案时同步两种语言，并保证网页承诺与 `SKILL.md`、脚本实际行为一致。

## 发布版本 ZIP

版本 ZIP 是给普通用户下载的完整包：解压后根目录里直接有“开始检查”和 `使用说明.txt`。

**`tools\Build-Release.ps1` 只在本机生成 ZIP 和校验文件，从不发布、上传、打标签、提交或推送。** GitHub Release 必须由维护者手动创建。下面以 `1.0.0` 为例，发布其他版本时换成对应版本号。

### 1. 更新版本号和更新日志

下面四处必须完全一致，否则构建会拒绝执行，而且不写出任何文件：

| 位置 | 写法 |
|---|---|
| 根目录 `VERSION` | 只有版本号加一个换行，例如 `1.0.0`；不要带 BOM |
| `scripts/Invoke-360Cleanup.ps1` | 一行单引号常量 `$script:ToolVersion = '1.0.0'` |
| `scripts/Windows360Cleaner.Library.ps1` | 一行单引号常量 `$script:W360ToolVersion = '1.0.0'` |
| `CHANGELOG.md` | 最新版本写在最前面，标题为 `## 1.0.0 - 2026-09-13`（版本号 + 空格 + `-` + 空格 + 日期），先中文后英文 |

窗口标题里的版本号和每份报告的 `ToolVersion` 来自这两个脚本常量。改版本时，也用编辑器全文搜索旧版本号，把 README、网站和指南里写明的版本一起更新。

### 2. 运行全部测试

在仓库根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-360Cleaner.ps1
```

测试包括语法检查、一次真实的只读扫描（报告写在临时文件夹）、在隔离临时目录里进行的安全测试、界面文字和布局测试、Agent 大白话摘要测试（`tests\Test-AgentSummary.ps1`），以及 `tests\Test-Packaging.ps1`（只在存在 `tools\Build-Release.ps1` 的仓库副本中运行，它会检查版本号一致性和 ZIP 内容）。最后必须显示 `All Windows 360 Cleaner test suites passed.`；推送后 GitHub Actions 的 Validate 也要通过。

不要为了“试一下发布包”在维护电脑上勾选并执行真实清理。

### 3.（可选）重新生成文档截图

界面文字或布局有变化时，重新生成截图：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-UiScreenshots.ps1
```

- **会生成哪些图。** `01-start-entry.png` 解压后的文件夹；`02-scan-progress.png` 正在检查电脑；`03-scan-results.png` 按软件分组的“删不删”列表（演示只勾选多绘屏保、保留 360 安全浏览器）；`04-confirm-delete.png` “确定要删除吗？”窗口；`05-cleanup-result.png` 删除完成；`06-home-after-restart.png` 重启后的“上次删除的记录”首页；`07-verify-result.png` 检查上次删除的结果。README、两份新手指南和网站的图片说明都按这些画面写，重新生成后如果画面内容变了，要一起改说明。
- **使用示例数据。** 它在隔离的临时示例文件夹上运行真实的只读检测和复检逻辑，把显示路径换成 `C:\Users\示例用户`，每张窗口截图顶部都有“示例数据截图”横幅。它不扫描、不删除这台电脑上的真实软件，不请求管理员权限，不运行 Remove 或厂商卸载程序，也不改服务、计划任务和注册表；截图故事里的“清理”只删除它自己临时示例目录里的文件夹。
- **需要正常登录的桌面。** 窗口会短暂置顶弹出，再从屏幕上截取；截图期间不要操作鼠标或遮挡窗口。加 `-UseDrawToBitmap` 可以改为直接绘制工具窗口，不从屏幕截取（`01-start-entry.png` 仍然从屏幕截取资源管理器）。
- **`01-start-entry.png`** 会先调用 `tools\Build-Release.ps1` 在临时文件夹里构建一个 ZIP（所以第 1 步的版本号必须已经一致），解压到“公用文档”下的临时 `W360-screenshot-…` 文件夹，打开资源管理器只截取文件列表区域，结束后删除该临时文件夹。加 `-SkipExplorerCapture` 可以跳过这张图：输出目录里已经有 `01-start-entry.png` 时会保留原图，重新生成的 `assets/screenshots/README.md` 表格里仍然有这一行；输出目录里没有这张图时（例如用 `-OutputDirectory` 输出到新文件夹），表格里就没有这一行。
- 默认覆盖 `assets/screenshots/` 下的 PNG 和 `README.md`；用 `-OutputDirectory` 可以输出到别处先检查。
- 提交前逐张打开图片，确认没有真实用户名、私人路径或其他窗口。保持文件名不变：README、新手指南和网站都引用这些文件名；网站使用 `raw.githubusercontent.com/.../main/...` 地址，合并到 main 后才会显示新图。
- `assets/screenshots/` 会被打进发布 ZIP，所以先更新截图并提交，再构建。

### 4. 构建 ZIP

构建脚本读取的是**当前工作区里的文件，包括还没提交的改动**。请在准备打标签的那个提交上构建，先确认 `git status` 没有未提交的改动：

```powershell
git status
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1
```

成功后得到两个文件，脚本会打印 SHA-256，并提示 `Nothing was published or uploaded.`：

- `dist\windows-360-cleaner-v1.0.0.zip`
- `dist\windows-360-cleaner-v1.0.0.zip.sha256`（一行内容：`<小写 SHA-256>  windows-360-cleaner-v1.0.0.zip`）

`dist/` 已在 `.gitignore` 中，不要提交。同名文件已经存在时构建会拒绝；确认要在发布前重新构建时才加 `-Force` 替换。已经上传到 Release 的文件不要用同一版本号重新构建替换，应该发新版本。`-OutputDirectory` 可以指定其他输出目录，但不能放在 `agents`、`scripts`、`tests`、`references`、`assets` 里面。

ZIP 里只有一个根文件夹 `windows-360-cleaner-v1.0.0/`，包含：

- `开始检查.cmd`、`Start-Check.cmd`、由模板生成的 `使用说明.txt`
- `README.md`、`README.en.md`、`SKILL.md`、`LICENSE`、`CHANGELOG.md`、`VERSION`
- `agents/`、`scripts/`、`tests/`、`references/`、`assets/readme/`、`assets/screenshots/`

不包含：`.git*`、`.github/`、`docs/`、`dist/`、`tools/`、`packaging/`，扫描/清理/复检报告（`360-cleanup-*.json`、`360-cleanup-*.txt`）、进度日志、`*.log`/`*.tmp`/`*.bak`/`*.zip`/`*.sha256` 文件、`reports` 文件夹，以及任何联接点或符号链接（会打印警告并跳过；必需的文件或文件夹是链接时直接拒绝）。仓库根目录如果有一个多余的 `使用说明.txt`，它不会被打包，ZIP 里的 `使用说明.txt` 始终由模板生成。以下情况构建也会拒绝，并且不写出任何文件：缺少必需的文件或文件夹（例如两个“开始检查”入口、`scripts` 里的四个核心脚本 `Invoke-360Cleanup.ps1`、`Select-360Cleanup.ps1`、`Windows360Cleaner.Library.ps1`、`Show-360Summary.ps1`，以及 `packaging/使用说明.txt` 模板）、模板里没有 `{{VERSION}}` 占位、某个 `.ps1` 不是 UTF-8 with BOM、某个 `.cmd` 含非 ASCII 字符或不是 CRLF 换行、输出目录是链接或是文件。

### 5. 检查 ZIP

1. 核对校验值，两行中的哈希必须相同（`Get-FileHash` 显示大写，`.sha256` 文件是小写，大小写不影响）：

   ```powershell
   Get-FileHash dist\windows-360-cleaner-v1.0.0.zip -Algorithm SHA256
   Get-Content dist\windows-360-cleaner-v1.0.0.zip.sha256
   ```

2. 把 ZIP 复制到一个新文件夹，像普通用户一样右键 → **全部解压**。确认只有一个根文件夹、上面列出的文件都在、中文文件名（`开始检查.cmd`、`使用说明.txt`）显示正常，并且没有 `docs`、`tools`、`packaging`、`.github` 或任何 `360-cleanup-*` 报告。
3. 打开 `使用说明.txt`，确认版本号已经填好，没有残留 `{{VERSION}}`。
4. 双击 `开始检查`：窗口标题应显示 `Windows 360 清理工具 v1.0.0`（Windows 显示语言不是中文时为 `Windows 360 Cleaner v1.0.0`）。等检查结束后直接点“关闭”，不要勾选、不要点“全选可以删除的”，也不要删除任何内容。如果桌面上有以前删除留下的记录，窗口会先显示“上次删除的记录”页面，这时点“重新检查电脑”即可。这次扫描会在桌面留下一份 `360-cleanup-scan-*.json`，不要把它提交到仓库或放进发布包。

### 6. 在 GitHub 手动创建 Release

构建脚本不会做这一步。需要仓库写权限，参考 [GitHub 管理 Release 的官方说明](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)：

1. 确认发布用的提交已经合并到 `main`，Validate 通过，并且第 4 步正是在这个提交上构建的。
2. 打开仓库的 **Releases** 页面，点击 **Draft a new release**。
3. 在标签选择框（**Choose a tag**，界面文字可能略有不同）中输入 `v1.0.0`（`v` + `VERSION` 里的版本号），选择创建新标签，目标分支为 `main`。
4. 标题写 `Windows 360 清理工具 v1.0.0 / Windows 360 Cleaner v1.0.0`。
5. 说明文字从 `CHANGELOG.md` 复制 `## 1.0.0 - 2026-09-13` 这一节（中文和英文）。建议在最前面加一句下载提示：用能运行本机命令的 AI Agent 时，把仓库或 ZIP 交给 Agent，对它说“帮我检查这台电脑上的 360 软件”；不用 Agent 时，下载 `windows-360-cleaner-v1.0.0.zip`，全部解压后双击“开始检查”；`.sha256` 文件用于核对下载是否完整。GitHub 自动附带的 **Source code (zip)** 是源代码快照，不是这个发布包（没有 `使用说明.txt`，还带有维护用文件夹），也请在说明里提醒。
6. 把 `windows-360-cleaner-v1.0.0.zip` 和 `windows-360-cleaner-v1.0.0.zip.sha256` 两个文件拖进附件区域，等上传完成。
7. 正式版本保持 **Set as the latest release**；只有测试版才勾选 **Set as a pre-release**。检查无误后点击 **Publish release**。

### 7. 发布之后

1. 用未登录的浏览器窗口打开 Release 页面，下载刚上传的 ZIP，再核对一次 SHA-256，全部解压后重复第 5 步的快速检查。
2. 确认 Release 已经公开后，可以（可选）把下载链接改为 Releases：`README.md`、`README.en.md`、两份新手指南、`docs/index.html`、`docs/en/index.html`。可以用总是指向最新版本的 `https://github.com/LongXL6/windows-360-cleaner/releases/latest`，或固定版本的 `https://github.com/LongXL6/windows-360-cleaner/releases/download/v1.0.0/windows-360-cleaner-v1.0.0.zip`。因为文件名里带版本号，固定版本链接每次发版都要改。
3. 没有实际发布证据前，不要在任何页面写“已发布”，也不要编造下载量。

## 本地预览与审阅

在仓库根目录运行（需要 Python 3）：

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory .
```

打开 `http://127.0.0.1:8765/docs/` 与 `http://127.0.0.1:8765/docs/en/`，审阅后在终端按 Ctrl+C 关闭。这里的 `/docs/` 是本地预览路径，正式项目站使用下面的 `/windows-360-cleaner/`。

- 用电脑和窄屏手机尺寸检查下载按钮、步骤、换语言、长路径换行以及键盘焦点。
- 检查 ZIP、指南、求助入口。PR 中新文件的 `blob/main/` 链接要等合并后才存在；审阅分支时从文件列表打开它们。
- 用 `git diff --check` 检查补丁，并确认现有 Validate CI 通过。
- 网页只介绍工具；ZIP 按钮下载仓库，不会在网页里扫描电脑。

## 发布配置与后续更新

当前正式地址是 `https://longxl6.github.io/windows-360-cleaner/`，英文页为 `https://longxl6.github.io/windows-360-cleaner/en/`。发布源已经配置，之后合并到 main 的页面变更会触发部署。需要恢复配置或在另一个仓库搭建时，可参考以下步骤：

1. 合并 PR，确认 main 包含 `docs/index.html` 和英文页。
2. 进入仓库 **Settings → Pages → Build and deployment**。
3. Source 选择 **Deploy from a branch**，Branch 选择 **main**，目录选择 **/docs**，保存。这一步会启动发布，不需要在每次更新时重复执行。
4. 等待 Pages 的构建和部署成功，读取 Settings 显示的实际网址。
5. 核对中文页、英文页、CSS、sitemap 和分享图能公开访问且返回成功响应。用手机实际点击下载与求助链接。

该方式使用 GitHub 自带的 Pages 发布流程，不需要额外部署工作流；`.nojekyll` 保持纯静态文件服务。步骤依据 [GitHub Pages 发布源说明](https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site)。

如果实际网址不同或日后绑定自定义域名，发布前同时修改两个 HTML 的 canonical、所有 hreflang、`og:url`、JSON-LD URL，以及 `sitemap.xml`。如果移动分享图，也更新两页的 `og:image` 与 `twitter:image`。不要只改可见链接而留下旧元数据。

## SEO 配置为什么这样写

两页把“360 软件扫描与清理 / scan and remove 360/Qihoo software”放进实际标题与正文，解释目标用户、步骤和结果，提供普通 `<a href>` 链接。正文直接在 HTML 中，无需 JavaScript 执行后才能读取。这遵循 [Google SEO 入门指南](https://developers.google.com/search/docs/fundamentals/seo-starter-guide) 的内容和可发现性原则。

- **Title / description**：按中英文分别填写，准确描述页面；不是保证显示的搜索摘要，也不堆叠同义关键词。
- **Canonical**：每页指向自己的正式 URL；英文页不能 canonical 到中文页。参考 [Google canonical 文档](https://developers.google.com/search/docs/crawling-indexing/consolidate-duplicate-urls)。
- **Hreflang**：两页互相声明 `zh-Hans`、`en` 与 `x-default`，都使用绝对 URL；默认入口为中文。正文保留可以点击的语言切换。参考 [Google 多语言页面指南](https://developers.google.com/search/docs/specialty/international/localized-versions)。
- **Open Graph / X 卡片**：描述用户分享链接时的标题、简介和配图，不是 Google 排名承诺；各平台可能裁切、缓存或不展示卡片，需要实际预览。
- **JSON-LD**：使用 `SoftwareSourceCode`，描述本页展示的开源代码库、PowerShell 与 MIT 许可证；不编造评分、下载量、报价或评价，也不承诺特殊搜索结果样式。
- **Sitemap**：只列两份正式 HTML 页面；不列 ZIP、脚本、报告、预览地址或重复的 `index.html` URL，不填写虚构更新时间。参考 [Google sitemap 指南](https://developers.google.com/search/docs/crawling-indexing/sitemaps/build-sitemap)。

**为什么没有 `docs/robots.txt`？** GitHub 项目站位于子路径，Google 读取的是 `https://longxl6.github.io/robots.txt`。本仓库的 `docs/robots.txt` 会变成 `/windows-360-cleaner/robots.txt`，无法充当主机根目录的 robots 文件，所以不放一个无效配置。没有该文件并不等于禁止收录；若以后使用能控制根目录的自定义站点，再按真实部署位置配置。参考 [Google robots.txt 规则](https://developers.google.com/crawling/docs/robots-txt/robots-txt-spec)。

## 发布后，让 Google 发现页面

1. 在 Google Search Console 添加完整的 **URL 前缀** 属性 `https://longxl6.github.io/windows-360-cleaner/`（若改域名则使用实际地址），并用控制台给出的真实方法完成所有权验证。可以把 HTML 验证文件按原文件名、原内容放入 `docs/`，或将真实 HTML meta 标签加到首页，再提交发布；不要预填示例 token。核对验证文件在控制台要求的精确 URL 无需登录即可访问；验证后保留文件或标签，以便周期复核。参考 [Search Console 所有权验证说明](https://support.google.com/webmasters/answer/9008080)。
2. 用 URL Inspection 检查中文与英文的正式 URL，核对可访问状态、页面抓取情况和 canonical。确认没有意外的 `noindex` 或抓取阻断。
3. 在 Sitemaps 提交正式地址 `https://longxl6.github.io/windows-360-cleaner/sitemap.xml`；如果换了域名，使用更新后的实际地址。
4. 必要时请求索引，并在之后查看控制台的页面索引与搜索表现。抓取、建立索引和获得搜索展示是不同阶段，提交 sitemap 不保证收录或排名。参考 [Google 请求重新抓取说明](https://developers.google.com/search/docs/crawling-indexing/ask-google-to-recrawl)。

首页已配置 Search Console 提供的公开 `google-site-verification` 元标记，请在后续编辑时保留。元标记存在本身不代表验证完成；验证、sitemap 提交和索引情况应以对应站点在 Search Console 中的实时状态为准。README 或页面正文不应写“Google 已收录”，除非已经有对应证据。

## 仓库 About 与分享预览，手动补充

网站、description 和 topics 已设置过。后续修改时保持与实际内容一致（description 建议按下面的新说法更新）；自定义 Social preview 可另外配置：

- **Description**：`Windows 360/Qihoo 检查与清理 AI Agent Skill：先检查、用大白话说删不删、你确认后才删、重启后再检查；附本地窗口。`
- **Topics**：`windows`、`powershell`、`agent-skills`、`codex`、`qihoo-360`、`uninstaller`。只选实际相关的标签。
- **Website**：填写 Settings 返回的实际 URL，并同步 README 的“项目网站”链接；目前已设置为上述正式地址。
- **Social preview**：在仓库 Settings → General → Social preview 上传检查过的 PNG/JPG/GIF。现有 `assets/readme/windows-360-cleaner-hero.jpg` 可作为素材；先检查小尺寸裁切是否仍能读清项目名，再考虑另做 1280×640 版本。

GitHub 仓库预览和自有网页的 Open Graph 是两个独立设置；改 HTML 不会设置 GitHub 仓库预览。尺寸/格式以 [GitHub 分享预览官方说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview) 为准。

## 最后发布检查

用无登录窗口打开正式页面、ZIP、两种语言的新手指南和求助入口；检查社交配图和界面截图里没有个人路径或未经同意的截图。发布了带版本号的 Release 后，再确认 Release 页面上的 ZIP 与 `.sha256` 可以下载且校验一致。选择 [社交文案包](social-sharing.md) 中的一份修改后再由你手动发布。没有部署证据就继续使用已经存在的 GitHub 仓库链接。
