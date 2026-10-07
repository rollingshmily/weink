# Weink

在 KOReader 上阅读微信读书的书籍、公众号文章（收藏 / 浮窗），并同步阅读进度与阅读时长。

> **免责声明**：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者概不负责。请遵守微信读书的用户协议和相关法律法规。

## 功能

- **书架**：书籍 / 文章收藏 / 微信浮窗三类分栏；支持排序、筛选与书架内搜索，已下载内容可离线打开
- **阅读**：把微信读书的书下载成 EPUB 阅读（整本、多章或按需），公众号文章单独缓存；页内脚注、章节预加载、封面自动嵌入
- **划线与想法**：阅读时点击正文里的划线即弹出该处想法；可在「划线与想法管理」里查看当前书关联的云端记录、继续加载，并逐条删除（删除前有确认）
- **阅读进度同步**：开书拉取、关书或休眠上传；两端不一致时开书会询问保留哪一侧，选完即走、不打扰
- **阅读时长上报**：按设置自动上报（可自动关联正在读的书，或手动指定一本），菜单里可查看上报次数、最近上报时间与错误信息
- **阅读统计**：按周 / 月 / 年 / 总维度查看阅读时长、阅读天数与排行
- **缓存管理**：图书目录与元数据目录分开设置，可分别扫描与清理；插件内更新不会清掉登录态与已下载内容
- **插件内更新**：菜单里检查 / 下载 / 安装新版本，国内网络可走加速通道
- **按键与手势**：方向键 / 翻页键可操作各列表页；书架、搜索、阅读统计、进度同步与阅读界面快捷菜单都能绑到手势或按键

## 安装

> 建议 **KOReader 2026.03 或更高版本**；旧版本可能无法正常加载插件，例如「工具」菜单里看不到入口。

**方式一：用 Release 包（推荐）**

1. 在本仓库 [Releases](https://github.com/rollingshmily/weread.koplugin/releases) 下载最新的 `weread.koplugin-v*.zip`。
2. 国内网络慢的话，可以在链接前加加速前缀，例如：

   ```
   https://runn.i.ng/<owner>/<repo>/releases/download/<tag>/<file>
   https://gh-proxy.com/https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
   https://ghfast.top/https://github.com/<owner>/<repo>/releases/download/<tag>/<file>
   ```

3. 解压，把 `weread.koplugin/` 放进 KOReader 的 `plugins/` 目录，重启 KOReader。

**方式二：手动复制源码目录**

把仓库里的 `_meta.lua`、`main.lua`、`weread/`、`fonts/`、`icons/`、`integrations/` 放进
`koreader/plugins/weread.koplugin/`，重启 KOReader。

装好后的入口：

```
工具 → 微信读书
```

**在设备上更新**

```
工具 → 微信读书 → 插件更新 → 检查更新
```

默认走 ghspeedup（`runn.i.ng` 路径模式）；也可以在菜单里改用 `gh-proxy.com` / `ghfast.top` / 直连，
检查与下载时会自动尝试备用通道。

## 登录

1. 打开 `工具 → 微信读书 → 账号`，选扫码登录。
2. 用微信扫码并在手机上确认授权（授权需包含收藏 / 浮窗）。
3. 凭证过期可在同一菜单里续期；续期失败就重新扫码。

## SimpleUI / Zen_UI 集成

插件提供统一的「微信读书书架」入口，可以挂到 [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin)
与 [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin) 上：

- **SimpleUI**：`快捷操作` 里新建操作，类型选 `插件 → 微信读书`，再把它加到底部栏。想用本项目的图标，
  就把 `icons/weread-w-book.svg` 或 `icons/weread-ink.png` 复制到 SimpleUI 的自定义图标目录后选中。
- **ZenUI 底栏**：`控件 → 按钮 → ➕ → 插件 → 微信读书`，点击直接打开书架。注册时会把 `weread-w-book.svg`
  同步到 KOReader 用户图标目录，供其自动匹配或手动选择。
- **ZenUI 首页**：`主页 → 小组件` 里启用「微信读书」组件（默认关闭，可自行排序）。

原生 `工具 → 微信读书` 菜单不受影响。

## 菜单在哪

装好之后功能都在 `工具 → 微信读书` 下面：

- **账号**：扫码登录、凭证续期、清除账号数据
- **书架 / 搜索**：书籍与公众号文章，也能直接搜微信读书
- **只在阅读时出现**：立即同步进度、书籍详情、显示划线和想法、划线与想法管理
- **阅读时间上报 / 阅读统计**：上报开关与触发方式、目标书籍、统计查看
- **设置**：缓存管理、进度管理、下载设置、划线设置、账号管理
- **插件更新**：检查更新、更新通道、加速通道选择
- **关于**：版本与项目说明

## 已知限制 / TODO

- [ ] 书签与笔记的独立展示（目前通过「划线与想法管理」查看云端记录）
- [ ] 进度冲突在本地偏移是估算值时的判定放宽（避免为很小的差异打断阅读）
- [ ] 云端回读坐标语义的受控验证
- 脚注显示自 1.2.84 起交给 KOReader 原生设置控制，插件不再提供开关；旧书需要删掉重新下载

## 贡献

欢迎提交 issue 和 PR；提交前请读一下 [CONTRIBUTING.md](CONTRIBUTING.md)。

本地书的划线与想法由插件自有的标注层投到正文上（不改 EPUB、不动 KOReader 笔记），
原理、失效时机、测试步骤与限制见[标注层说明](docs/annotations-overlay.md)。

## 许可证

本项目代码采用 [GNU Affero General Public License v3.0](LICENSE)，SPDX 标识 `AGPL-3.0-only`。

修改、整合或再分发时必须遵守 AGPL-3.0：保留版权与许可证声明，并按许可证要求开源你的修改。

`fonts/NotoEmoji-Regular.ttf` 是第三方字体，采用 [SIL Open Font License 1.1](fonts/LICENSE)，不适用本项目的 AGPL-3.0。

Copyright © 2026 finlater and contributors（本项目源自其 AGPL-3.0 工程）。  
Copyright © 2026 rollingshmily and contributors（Weink 部分）。
