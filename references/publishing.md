# 网站发布、搜索发现与日常维护

[返回首页](../README.md) · [社交文案包](social-sharing.md)

项目网站已于 2026-09-05 通过 GitHub Pages 发布：[中文](https://longxl6.github.io/windows-360-cleaner/) · [English](https://longxl6.github.io/windows-360-cleaner/en/)。发布源为 `main` 的 `/docs`，HTTPS 已开启，仓库 About 的网站、description 和 topics 已设置。当前状态应以 Pages 设置、部署运行和公开页面为准；上线不等于 Google 已收录。

## 修改什么文件

| 想改的内容 | 文件 |
|---|---|
| GitHub 首页与下载入口 | `README.md`、`README.en.md` |
| 新手步骤、结果解释与常见问题 | `references/getting-started.md`、`references/getting-started.en.md` |
| 各平台标题、正文、口播和素材安排 | `references/social-sharing.md` |
| 网站中文与英文正文、分享卡片文案 | `docs/index.html`、`docs/en/index.html` |
| 字体、颜色、间距和手机排版 | `docs/styles.css` |
| 正式页面地址列表 | `docs/sitemap.xml` |

网站无需构建、JavaScript、账号或第三方统计。修改文案时同步两种语言，并保证网页承诺与 `SKILL.md`、脚本实际行为一致。

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

网站、description 和 topics 已设置。后续修改时保持与实际内容一致；自定义 Social preview 可另外配置：

- **Description**：`Windows 360/Qihoo 扫描与清理 Skill：先扫描、人工批准、重启验证。支持 Codex 与手动脚本。`
- **Topics**：`windows`、`powershell`、`agent-skills`、`codex`、`qihoo-360`、`uninstaller`。只选实际相关的标签。
- **Website**：填写 Settings 返回的实际 URL，并同步 README 的“项目网站”链接；目前已设置为上述正式地址。
- **Social preview**：在仓库 Settings → General → Social preview 上传检查过的 PNG/JPG/GIF。现有 `assets/readme/windows-360-cleaner-hero.jpg` 可作为素材；先检查小尺寸裁切是否仍能读清项目名，再考虑另做 1280×640 版本。

GitHub 仓库预览和自有网页的 Open Graph 是两个独立设置；改 HTML 不会设置 GitHub 仓库预览。尺寸/格式以 [GitHub 分享预览官方说明](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview) 为准。

## 最后发布检查

用无登录窗口打开正式页面、ZIP、两种语言的新手指南和求助入口；检查社交配图里没有个人路径或未经同意的截图。选择 [社交文案包](social-sharing.md) 中的一份修改后再由你手动发布。没有部署证据就继续使用已经存在的 GitHub 仓库链接。
