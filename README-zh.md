# FullFloatPiP

**[English](README.md) | 中文**

**画中画，浮在一切之上——包括全屏应用。**

唯一能创建真正始终置顶浮动视频窗口的 Chrome 扩展——浮在**所有**应用之上，包括全屏 Terminal、全屏 IDE、全屏任何应用。专为 vibe coding 开发者打造，让你在编码时同时观看视频、教程或直播。

> 没有任何其他画中画工具、Chrome 扩展或浏览器功能能让视频浮在 macOS 全屏应用之上。FullFloatPiP 可以。

<p align="center">
  <img src="docs/demo.png" alt="FullFloatPiP 浮在全屏 Terminal 之上" width="640">
  <br>
  <sub><i>FullFloatPiP 窗口浮在全屏 Terminal 之上——浏览器都不在屏幕上，视频依然持续播放。</i></sub>
</p>

## 为什么选择 FullFloatPiP？

所有现有的画中画方案在你切到全屏时都会失效：

| 功能 | Chrome 内置 PiP | PiPifier (Safari) | 其他扩展 | **FullFloatPiP** |
|---|---|---|---|---|
| 浮在普通窗口之上 | 是 | 是 | 是 | **是** |
| 浮在全屏应用之上 | 否 | 否 | 否 | **是** |
| 跨所有 Space/桌面可见 | 否 | 部分 | 否 | **是** |
| YouTube 风格控制栏 | 否 | 否 | 不一定 | **是** |
| 支持任意视频网站 | 有限 | 仅 Safari | 不一定 | **是** |

**核心问题：** Chrome 浏览器沙盒限制无法创建覆盖全屏应用的窗口。FullFloatPiP 通过混合架构解决——Chrome 扩展负责视频检测，搭配 macOS 原生应用 (Swift/AppKit) 创建系统级浮动窗口。

## 专为 Vibe Coding 打造

Vibe coding 意味着保持心流——全屏 Terminal 或 IDE，零干扰，专注编码。但有时你想在角落里放一个教程视频、技术演讲或 lo-fi 音乐。

使用 FullFloatPiP：
1. 在 Chrome 中打开 YouTube（或 B站、Twitch 等）
2. 点击 FullFloatPiP 图标，选择视频，点击 **Float**
3. 切换到全屏 Terminal / VS Code / Cursor / Xcode
4. 视频始终浮在角落——永远可见，永远置顶

无需切换窗口。无需分屏。无需退出全屏。代码和视频，同时拥有。

## 功能特性

- **真正始终置顶** — 浮在所有应用上方，包括 macOS 全屏应用
- **跨 Space 显示** — 在所有 macOS 桌面/Space 中可见
- **PiP 风格界面** — 无边框视频窗口，鼠标悬停时显示控制栏
- **YouTube 风格控制栏** — 播放/暂停、快进10秒、音量滑块、进度条拖拽、时间显示
- **自动视频检测** — 角标显示视频数量，自动检测 SPA 导航（YouTube、B站）
- **锁定宽高比** — 缩放时保持视频原始比例
- **记忆位置和大小** — 下次打开时恢复上次的窗口位置
- **拖拽 & 缩放** — 标题栏拖拽移动，任意边角缩放
- **透明度切换** — 半透明模式，减少视觉遮挡
- **多站点支持** — YouTube、B站、Twitch、优酷、爱奇艺、腾讯视频、抖音、Netflix* 以及任何含 HTML5 视频的网站

## 支持的视频网站

| 网站 | 加载策略 | 说明 |
|---|---|---|
| YouTube | 通过本地 HTTP 服务器嵌入 | Cookie 转发，Referer 修复 Error 153 |
| B站 (Bilibili) | 播放器嵌入 | 高画质，无弹幕 |
| Twitch | 播放器嵌入 | 支持直播 |
| 优酷 | 播放器嵌入 | — |
| 爱奇艺 | 全页加载 + JS 注入 | — |
| 腾讯视频 | 全页加载 + JS 注入 | — |
| 抖音 | 全页加载 + JS 注入 | — |
| Netflix | — | DRM 保护，无法播放* |
| 其他网站 | 自动检测 `<video>` 元素 | 回退到全页加载 + JS 隔离视频 |

## 安装

### 系统要求

- macOS 12 (Monterey) 或更高版本
- Google Chrome 浏览器
- Xcode Command Line Tools

### 安装步骤

```bash
# 1. 安装 Xcode 命令行工具（如果尚未安装）
xcode-select --install

# 2. 克隆仓库
git clone https://github.com/Sigmame/full-float-pip.git
cd full-float-pip

# 3. 运行安装脚本
chmod +x scripts/install.sh
./scripts/install.sh
```

安装脚本会自动：
1. 编译 Swift 原生应用
2. 安装可执行文件到 `~/Library/Application Support/FloatVideo/`
3. 配置 Chrome Native Messaging Host
4. 提示你加载 Chrome 扩展

然后在 Chrome 中加载扩展：
1. 打开 `chrome://extensions`
2. 开启**开发者模式**
3. 点击**加载已解压的扩展程序**，选择 `extension/` 文件夹
4. 复制扩展 ID，在安装脚本提示时输入

## 使用方法

1. 打开任意视频网站（YouTube、B站等）
2. 点击工具栏中的 **FullFloatPiP** 图标——角标显示检测到的视频数量
3. 选择视频并点击 **Float**
4. 视频弹出到浮动窗口，显示加载动画
5. 切换到任意应用（包括全屏应用）——视频始终浮在最上层

### 控制（鼠标悬停时显示）

- **标题栏** — 拖拽移动；关闭(红)、透明度切换(黄)、置顶指示(绿)
- **进度条** — 点击任意位置跳转；红色条显示播放进度
- **播放/暂停** — 切换播放状态
- **快进 10 秒** — 向前跳转 10 秒
- **音量** — 静音切换 + 滑块
- **时间显示** — 当前位置 / 总时长
- **ESC** — 关闭浮动窗口
- **缩放** — 拖任意边/角、控制条左右边缘、条上的 `+/-` 按钮、Option+滚轮，或快捷键 `⌃⌥=` / `⌃⌥-`（锁定宽高比）
- **自动避让** — 避开 Cursor、VS Code、Antigravity、Orca、Pi / Oh My Pi、终端与常见 AI coding 窗口

## 技术架构

```
Chrome 扩展 ──[Native Messaging (stdio)]──> Swift 原生应用
 (视频检测与提取)                              (浮动窗口与视频播放)
```

### 架构说明

FullFloatPiP 采用双组件架构，绕过 Chrome 浏览器的沙盒限制：

**Chrome 扩展 (Manifest V3)**
- `content.js` — 注入到网页中，检测 `<video>` 元素，提取视频源、标题、尺寸。通过 MutationObserver 监测 SPA 导航。
- `background.js` — Service Worker。桥接 Content Script/Popup 与原生应用，通过 Chrome Native Messaging API 通信。管理进程生命周期。
- `popup.js` — 扩展弹出界面。显示检测到的视频和 "Float" 按钮。

**macOS 原生应用 (Swift)**
- `AppDelegate.swift` — 接收来自 Chrome 的消息，路由 open/close/ping 操作。
- `FloatWindow.swift` — 核心实现。创建 `NSPanel`，窗口层级设为 `maximumWindow + 1`，集合行为设为 `canJoinAllSpaces` + `fullScreenAuxiliary`。这就是它能浮在全屏应用之上、在所有 Space 可见的原因。
- `LocalHTTPServer.swift` — 随机端口的临时 HTTP 服务器。为 YouTube 嵌入页面提供正确的 `Referer` 头以避免 Error 153。包含 YouTube IFrame API 桥接，用于播放控制。
- `NativeMessageHandler.swift` — Chrome Native Messaging 协议实现（4 字节小端序长度前缀 + UTF-8 JSON）。

### 视频加载策略

原生应用使用基于优先级的加载策略：

1. **直接视频源** — 如果 `<video>` 元素有非 blob 的 `src`，直接加载到 `<video>` 标签
2. **YouTube 通过本地 HTTP 服务器** — 嵌入 YouTube iframe，提供正确的 Referer、Cookie 注入和 IFrame API 控制
3. **站点专用嵌入** — 使用干净的播放器嵌入页面（B站播放器、Twitch 播放器、优酷嵌入）
4. **全页加载 + JS 注入** — 在 WKWebView 中加载整个页面，然后注入 JavaScript 隔离并最大化视频元素（隐藏非祖先链 DOM 节点，将视频设为 `position: fixed; 100vw x 100vh`）

### 为什么不直接用 Chrome 的 PiP？

Chrome 内置的画中画使用浏览器自身的窗口管理。在 macOS 上，浏览器窗口无法放置在全屏应用之上——这是操作系统层面的限制。FullFloatPiP 通过使用**原生 macOS 应用**的 `NSPanel` 并设置最高窗口层级来绕过这个限制，操作系统允许这种窗口浮在全屏应用之上。

## 已知限制

- **DRM 内容** — Netflix、Disney+ 等使用 Widevine DRM 的平台无法在浮动窗口中播放
- **Blob URL** — 某些网站使用 Blob URL 进行视频流传输，会回退到全页加载 + JS 注入
- **Cookie 不共享** — 浮动窗口与 Chrome 不共享登录态，部分网站可能需要重新登录
- **仅支持 macOS** — 需要 macOS 12+ 和原生 Swift 伴生应用，不支持 Windows/Linux

## 卸载

```bash
chmod +x scripts/uninstall.sh
./scripts/uninstall.sh
```

然后在 `chrome://extensions` 中手动删除扩展。

## 许可证

MIT

## 贡献

欢迎提交 Issue 和 Pull Request。重大修改请先开 Issue 讨论。
