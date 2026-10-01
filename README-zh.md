# VibeFloat（FullFloatPiP）

**[English](README.md) | 中文**

**一个电影目录加一个悬浮在一切之上的播放器 —— 包括全屏应用。**

VibeFloat 是一个独立的 macOS 应用。在它自己的窗口里浏览电影，点击 **Phát nổi**，视频就会以无边框窗口悬浮在所有应用之上 —— 全屏终端、全屏 IDE、任何全屏程序 —— 并且在每个桌面空间都可见。专为一边写代码、一边看电影、教程或直播的开发者设计。

<p align="center">
  <img src="docs/demo.png" alt="VibeFloat 悬浮在全屏终端之上" width="640">
  <br>
  <sub><i>播放器悬浮在全屏终端之上。</i></sub>
</p>

## 功能

- **目录窗口** —— 首页有大图和多个分类行（院线、配音、剧集、动漫、电影）、搜索、分类、类型和国家、无限滚动网格，以及带剧集和相似影片的详情窗口。方向键在卡片之间移动；鼠标停在卡片上会出现预览。
- **你的列表** —— *Danh sách của tôi*（收藏）、带进度条的 *Tiếp tục xem*、*Đã xem*（标记已看/未看）和 *Đã ẩn*（隐藏不喜欢的电影；被隐藏的片子会从所有行和列表中消失，并且可以恢复）。右键点击卡片、点击卡片上的 ⋯ 按钮，或在选中的卡片上按 **W**（已看）/ **H**（隐藏）。
- **YouTube 影片** —— 来自发行方频道的近年亚洲影片精选列表，带搜索和筛选。见 [筛选策略](docs/youtube-movies.md)。
- **悬浮播放器** —— 始终置顶、所有空间可见、YouTube 风格控制条、快进快退、音量、倍速、尺寸预设、透明度、点击穿透、带自动下一集和跳过片头的剧集导航，以及可选的离线越南语配音。
- **菜单栏和 Dock 菜单** —— 打开目录、暂停或关闭播放器、继续观看、切换点击穿透和 AI 配音、退出。
- 播放器打开时的**全局快捷键**（例如 ⌘⇧G 点击穿透）。

## 安装

要求：macOS 12 (Monterey) 或更高版本，以及 Xcode Command Line Tools。不需要浏览器。

```bash
xcode-select --install                      # 如果还没有命令行工具，只需一次
git clone https://github.com/Sigmame/full-float-pip.git
cd full-float-pip
./scripts/install.sh
open "$HOME/Library/Application Support/FloatVideo/VibeFloat.app"
```

脚本会编译应用，把它安装到 `~/Library/Application Support/FloatVideo/`（目录界面在应用包内），为本机做临时签名，并清除旧的 Chrome 方案留下的文件。重新安装后请退出应用（⌘Q）再重新打开。卸载：`./scripts/uninstall.sh`（保留你保存的列表；`--purge` 会一并删除）。

## 使用

1. 打开 VibeFloat。选一部电影（卡片、大图、详情窗口），点击 **Phát nổi**。
2. 切换到任何应用，即使全屏：播放器始终在最上层。关闭目录窗口不会停止播放。
3. 鼠标移到播放器上会出现控制条：拖动标题栏移动，点击时间轴跳转，ESC 关闭，拖动边缘调整大小（锁定宽高比）。

**尺寸。** 播放器菜单提供 Small（480 pt）、Medium（640 pt）和 Wide（最宽 960 pt），并记住上次的选择。Wide 不超过可见屏幕宽度的 75% 和包含控制条在内的 85% 高度预算；自动摆放会尽量保持所选尺寸。

**默认值。** 点击穿透默认**关闭**，也不会被自动打开。AI 配音默认**关闭**，需要你明确开启；播放器里的离线配音同样默认关闭。

## 安全范围

- 目录只访问电影提供方（`phimapi.com`、`ophim1.com`、`ophim.com`、`nguonc.com`、`streamc.xyz`、`kkphim.com`、`kkphimplayer.com`、`kkphimplayer6.com` 及其子域名）和封面图主机 `phimimg.com`。请求由应用代发：仅 GET/HEAD、仅 HTTPS、不带 cookie、上限 12 MB，重定向会按同一名单重新检查。页面不能嵌入任何框架，并带有内容安全策略。
- 播放器把远程页面和 iframe 的导航限制在这些提供方内；媒体 CDN 请求不受影响。YouTube 只播放审核名单里的确切视频 ID。
- 目录数据（收藏、标记、进度、缓存）是一个私有 JSON 文件：`~/Library/Application Support/FloatVideo/catalog-storage.json`。
- 本地控制工具 `scripts/vibe-sync.sh` 在应用运行时读取 `~/.floatvideo_token` 中的私有令牌；直接调用 `/api/` 需要 `X-VibeFloat-Token` 头。

## 工作原理

```
VibeFloat.app
 ├─ 目录窗口   ── WKWebView，从应用包以 vibe://app/ 显示 native-app/Catalog（HTML/CSS/JS）
 │                  └─ Swift 桥：存储、网络、"Phát nổi"、状态               (CatalogBridge.swift)
 ├─ 悬浮播放器 ── 位于全屏应用之上的 NSPanel，所有空间可见                    (FloatWindow.swift)
 ├─ 本地 HTTP  ── 带有效 Referer 的 YouTube 嵌入页和 /api/ 控制接口         (LocalHTTPServer.swift)
 └─ 菜单栏+Dock ── 快捷操作                                                  (MenuBarController.swift)
```

- `FloatWindow.swift` 创建窗口层级为 `maximumWindow + 1`、集合行为为 `canJoinAllSpaces` + `fullScreenAuxiliary` 的 `NSPanel`，这正是它能悬浮在全屏应用之上并出现在每个空间的原因。
- `CatalogWindow.swift` / `CatalogBridge.swift` / `CatalogSupport.swift` 提供应用包内的界面、响应其 `chrome.*` 风格的调用，并包含经过测试的纯逻辑部分（网络策略、文件路径、存储、进度）。
- `native-app/Catalog/` 是整个目录界面：`catalog.html|css|js`、`movie-service.js`（提供方、缓存、列表）、`site-access.js`（审核过的 YouTube 影片）、`dub-preference.js`。

### 从 Chrome 扩展迁移

Chrome 扩展及其 native-messaging 宿主已移除。扩展能做而应用不能做的事：检测你浏览器里打开页面上的 `<video>` 并从那里悬浮，以及为浏览器标签朗读页面字幕。其余一切 —— 目录、列表、YouTube 影片、悬浮播放器及其控制 —— 都在应用里。保存在扩展里的收藏和标记不会被复制过来。安装脚本会删除旧的 native-messaging 清单；请在 `chrome://extensions` 手动移除扩展本身。

## 开发

```bash
cd native-app
swift build                                   # 调试构建
for t in Catalog/tests/*.test.js; do node "$t"; done
swiftc -swift-version 5 Sources/CatalogSupport.swift tests/catalog-support.swift -o /tmp/catalog-support && /tmp/catalog-support
```

`VIBEFLOAT_HOME=/some/folder` 让应用的数据、端口文件和令牌不碰你真实的主目录；`VIBEFLOAT_CATALOG_DIR` 从某个文件夹而不是应用包提供目录界面（无需重装即可改界面）；`VIBEFLOAT_CATALOG_SELFTEST_JS` / `_OUT` 在已加载的窗口里运行脚本并写出 JSON 结果。

## 已知限制

- **DRM 内容**（Netflix、Disney+ 及其他 Widevine 平台）无法在悬浮窗口中播放。
- **不共享登录状态**；需要登录的网站不受支持。
- **仅限 macOS**（12+），在本机构建和签名；暂无经过公证的下载包。

## 许可证

MIT

## 贡献

欢迎提交 Issue 和 Pull Request。重大改动请先开 Issue 讨论。
