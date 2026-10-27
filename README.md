# dsh-cua

把 Codex Desktop 的 Computer Use 能力移植到 DeepSeek Harness —— 一个独立的 dsh 插件包。

模型能像在 Codex 里一样看屏幕、读界面结构、点按输入：`get_app_state` 返回**辅助功能树文本 + 截图**，
动作工具按元素 ID 或坐标投递 CGEvent。

---

## 为什么不直接复用 SkyComputerUseService

Codex 的 Computer Use 服务有一条代码签名鉴权（`-10000 senderProcessNotAuthenticated`）：
`SecCodeCopyGuestWithAttributes` 取调用方 TeamID，必须是 `2DC432GLL2` 且在 identifier 白名单内，
还要查 responsible process 与父进程。从 harness 直接调用必然被拒。

本插件换一条路：**自己实现服务**。AXUIElement / ScreenCaptureKit / CGEvent 都是系统公开 API，
不需要任何 OpenAI 签名。实测当前 harness 进程已持有辅助功能与屏幕录制授权，
三项能力（AX 遍历、SCK 截图、`CGEvent.postToPid`）全部可用。

代价是没有 Codex 那些上层工程化能力（AX 树 diff、元素失效重取、SkyshotClassifier、
画中画远程渲染、锁屏处理）。这些在下面「与 Codex 实现的差距」里逐条列出。

---

## 安装

仓库已内置预编译二进制（`bin/cua-mcp`、`bin/cua-overlay`，universal：x86_64 + arm64），
**不需要构建，不需要 Xcode**。

```bash
# 从 GitHub 装
dsh plugin --profile web add github:SwallOwDili/dsh-cua

# 或从本地目录装
dsh plugin --profile web add file:/path/to/dsh-cua
```

`add` 之后 dsh 会把声明了 `dsh.bundle` 的包自动并入 layer 栈，`mcp-computer-use`
这一行随之生效（不需要手改 `dsh.profile.bundles`）。
如果提示「declares no dsh.bundle」，说明 `package.json` 里的 `dsh.bundle.patch` 丢了。

### 自行构建（可选）

只在改了 `src/main.swift` 或 `overlay/main.swift` 之后才需要：

```bash
./build.sh    # 需要 Xcode Command Line Tools
```

脚本用两个 `-target` 各编一次再用 `lipo` 合并成 universal，
并把产物同步到已安装的 profile（`$DSH_PROFILE` 或自动扫描 `~/.dsh/profiles/*`）。

### 授权

首次使用前确认承载 harness 的进程（终端、或 DSH Desktop）已获得：

- **辅助功能**（Accessibility）—— AX 树读取与 CGEvent 注入
- **屏幕录制**（Screen Recording）—— 截图

在 系统设置 → 隐私与安全性 中勾选，然后重启 harness。

```bash
./bin/cua-mcp --selftest   # 三项权限一次看清
```

---

## 模型看到的工具

经 `dsh-mcp-client` 注册后，工具名带命名空间前缀 `mcp__computer_use__<tool>`：

| 工具 | 作用 |
|---|---|
| `list_apps` | 列出运行中的图形应用 |
| `get_app_state` | AX 树文本 + 截图；返回的 `[数字]` 供后续动作用 |
| `click` | 点元素中心或屏幕坐标，支持双击、右键 |
| `type_text` | Unicode 直接注入，不走剪贴板 |
| `press_key` | 按键 / 组合键，`return`、`cmd+c`、`shift+tab` |
| `scroll` | 按页滚动，可指定元素或坐标 |
| `set_value` | 直接写元素 value |
| `select_text` | 在文本元素里选中子串 |
| `paste` | 走剪贴板并还原用户原剪贴板 |
| `perform_secondary_action` | AXPress / AXShowMenu / AXConfirm / AXRaise 等 |
| `drag` | 屏幕坐标拖拽 |

### AX 树文本格式

```
App: 访达 (pid 476)
Focused: [90] AXList <AXCollectionList> desc="图标视图" (focused) actions=[AXShowMenu]
Elements: 122
[1] AXWindow <AXStandardWindow> "dist" actions=[AXRaise]
  [2] AXSplitGroup
    [3] AXScrollArea actions=[AXScrollLeftByPage,AXScrollRightByPage,...]
      [4] AXOutline desc="边栏" actions=[AXShowMenu]
        [5] AXRow <AXOutlineRow> actions=[AXShowDefaultUI,AXShowAlternateUI]
          [6] AXCell
            [7] AXStaticText value="个人收藏"
```

行结构：`缩进 + [ID] + 角色 + <子角色> + 标题 + desc/value/placeholder + 状态 + actions`。
缩进两个空格，节点上限 4000，深度上限 60。

`(focused)` 是拿 `AXFocusedUIElement` 做 `CFEqual` 比对得出的，**不是**读元素自己的
`AXFocused` 属性 —— 后者在 `AXCell` 上会成片返回 true，会误导模型。

---

## 实现要点

**元素 ID 是单调递增的整数，跨快照不复用。** 每次 `get_app_state` 重建登记表，
旧 ID 立即失效并报错提示刷新。这与 Codex 的「带失效检测的可重取引用」不同：
这里是**快照语义**，不尝试自动重取。模型被要求「改完界面就重新 get_app_state」，
比 Codex 更笨但更可预测。

**坐标来自 AX 的 position + size 中心点。** 不做 Codex 那套
`scalingFactor` + `windowUsesFlippedCoordinates` 的窗口坐标系变换 —— 因为
AX 返回的已经是屏幕全局坐标，不需要额外换算。这也是我实测确认的一点：
直接在 AX 坐标系里 post 事件，落点准确。

**配置页。** 插件向 harness 的 settings 系统注册了 `cua` 命名空间，
UI 路径：**设置 → 插件 → 插件配置**，表单由 `dsh-client-schema-form`
按 schema 自动渲染（不需要写前端）。改动落到 `~/.dsh/dsh-cua.config.json`，
`cua-mcp` 每次工具调用前按 mtime 热读，**改完立即生效，不用重启 harness**。

| 配置项 | 默认 | 说明 |
|---|---|---|
| `browserCdpPort` | 0 | 0=自动读 DevToolsActivePort；指定则强制用该端口 |
| `browserCdpHost` | 127.0.0.1 | CDP 主机 |
| `overlayEnabled` | true | 「AI 正在操作」标记 + 橙色虚拟光标 |
| `overlayTtlSeconds` | 20 | 标记/光标静止后保留秒数 |
| `backgroundSilence` | true | 后台静默（postToPid 定向投递，不抢焦点）|
| `scrollStepPx` | 40 | 滚动单步像素（过大 Catalyst 会丢事件）|
| `maxElements` | 4000 | AX 快照节点上限 |

`Config`（cordis 层）仍是部署侧参数：`binary` / `checkPermissions` /
`failOnPermissionError`，写在 `cordis.patch.yml`，不进设置页。

**浏览器后台 tab 走 CDP，不走 GUI。** 浏览器的非活动 tab 不渲染，AX 树里没有它的
内容，`postToPid` 的点击/键入只能落到活动 tab 的渲染焦点——所以要在同一窗口里操作
另一个 tab 而不打断用户，GUI 层做不到。Codex 也是同样结论：`ChatGPT.app` 资源内命中
`remote-debugging-port` / `Target.getTargets` / `Page.captureScreenshot` / `attachToTarget`。

本插件实现同一通道，4 个工具：

| 工具 | 作用 |
|---|---|
| `browser_tabs` | 列全 tab（序号 / 标题 / URL / id），不激活 |
| `browser_eval` | 在指定 tab 跑 JS（`tab` 可用序号、id 前缀、URL 子串）|
| `browser_screenshot` | tab 级截图，不截窗口、不影响前台 |
| `browser_open` | 后台开新 tab（PUT /json/new，不抢焦点）|

前提：浏览器须以 `--remote-debugging-port=9222` 启动。端口只在启动时绑定，热开不了，
所以要么重启现有浏览器（会恢复上次标签），要么另起隔离实例：

```bash
# 复用用户登录态：完全退出后带参数启动（Chrome 会恢复会话）
osascript -e 'quit app "Google Chrome"'; sleep 1
open -a "Google Chrome" --args --remote-debugging-port=9222

# 完全隔离，不碰用户浏览器
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --user-data-dir=/tmp/cdp-profile --remote-debugging-port=9222
```

端口自动发现路径：`~/Library/Application Support/{Google/Chrome,Microsoft Edge,
BraveSoftware/Brave-Browser,Chromium}/DevToolsActivePort`；也可显式传 `port`。

**虚拟光标（overlay v5）。** 每个动作在屏幕上留下可见的橙色指针，用户能看见
AI 的「手指」在哪：click 在落点扩一圈涟漪后常驻，scroll / drag 滑向作用点，
停 20 秒自动消失。指针是 64pt 窗口里的橙色系统箭头（#FF8000）+ 白描边 + 阴影，
60fps easeOutCubic 缓动 0.28s 到位。click 走 `postToPid` 时真实光标不动，
虚拟光标就是唯一的可见锚点；scroll / drag 走 HID 时真实光标会动，虚拟光标与它同步。
（Codex 用 44 帧 LensSequence 做镜头动效，这里简化为静态指针 + 涟漪，未做帧动画。）

**事件路由分两路：`postToPid` 与 HID tap。**
click / type_text / press_key 走 `postToPid`：不动真实光标，后台静默可达。
scroll / drag 走 `CGEventPost(.cghidEventTap)` + began/changed/ended phase 序列：
Catalyst 应用（如 Infuse）的手势识别器会丢弃定向投递的滚动/拖拽事件，
`AXScrollDownByPage` 也只在 AX 层返回 success 而不真正滚动，只有 WindowServer
路由的真实事件才被处理（实测 2026-10-27，Infuse 8.5.8）。HID 是真实系统输入，
会真实移动光标、作用于光标下最顶层窗口，所以 scroll / drag 前会先把目标带到前台。
这正是 Codex `SyntheticAppFocusEnforcer.clickEventTap` 的用途。

**后台静默靠 AX 合成激活，不调用 `NSRunningApplication.activate`。**
Chrome 这类应用会丢弃后台状态下收到的合成鼠标事件，早期版本靠真的激活窗口
来绕过，副作用是抢走用户的前台应用。现在改为 `synthesizeActivation()`：
把目标窗口设为 `AXMain` / `AXFocused`，让应用「自认为」可接收事件，
系统的 frontmost 保持不变。实测：Edge 保持前台时，Chrome 的地址栏仍能被
`type_text` 写入、元素仍能被 `click` 命中。

Codex 的对应实现是 `SyntheticAppFocusEnforcer`，它的 State 有三个独立位：
`applicationIsActive`、`applicationBelievesItIsActive`、
`applicationBelievesItHasFocus`。这里只复现第三位，用的是公开 AX 属性，
没有它那套 `clickEventTap` / `activationEventSuppression` 事件层欺骗。

**截图用 `SCScreenshotManager.captureImage`。** 单帧抓取，不走 `SCStream` 持续流，
也不需要 SkyLight 私有路径。默认最长边 1600 px、JPEG 质量 0.6，通过
`max_dimension` / `quality` 可调。只截目标 app 的窗口，不截整个桌面。

**`type_text` 用 `keyboardSetUnicodeString`。** 每批 20 个 UTF-16 单元，
不依赖键盘布局，中文和 emoji 都能直接进。`press_key` 才走键码表，支持修饰键组合。

**`paste` 会还原剪贴板。** 保存所有 pasteboard item 的原始类型与数据，
粘贴后写回。这是 Codex 也有的一项用户保护。

---

## 实时画面

AI 在后台操作时，对话页右上角会出现一个小窗，实时显示它正在点哪个窗口。
前台还是你自己的窗口，不会被抢走——这是「能看见它在干什么」和「黑盒等结果」的区别。

实现走 MJPEG：`bin/cua-live` 常驻，以 3fps 抓目标窗口、缩到 480px 宽编码 JPEG，
对外是 `multipart/x-mixed-replace` 流；前端只是把这个流塞进一个 `<img>`，
浏览器自己维持刷新，不需要 WebSocket，也不需要 canvas。

| 端点 | 作用 |
|---|---|
| `GET /live.mjpg` | MJPEG 流，供 `<img>` 持续显示 |
| `GET /status` | `{active, app, pid, seq, viewers}`，决定小窗显不显示 |
| `GET /target?pid=&app=&ttl=` | 设置被抓的目标窗口 |
| `GET /clear` | 立即停止 |

只在有操作目标时抓帧：目标由 `Overlay.mark` 同步带过来，`ttl`（默认 20 秒）到期
自动停，静止时 CPU 归零。实测 3fps 抓帧期间 CPU 1.5%、内存 8.6MB、单帧 21KB。

端口固定 `127.0.0.1:18901` 而不走宿主 `webServer`：跨端口的 `<img>` 不受 CORS 约束，
从而绕开宿主那层登录中间件（走宿主路由会被拦成登录页）。

## 与 Codex 实现的差距

诚实列出，不粉饰：

| 能力 | Codex | dsh-cua |
|---|---|---|
| AX 树 diff | 三档 diff，省 token | 无，每次全量 |
| 元素失效重取 | `RefetchableUIElement` + invalidation monitor | 无，快照语义 |
| 截图按需分类 | `SkyshotClassifier` 判断是否要截图 | 无，按参数决定 |
| 虚拟光标动画 | `ComputerUseCursor` + Lens 帧 | 无 |
| 实时画面回显 | `RemoteHostedPIP*` 全套 | 已实现：对话页右上角 MJPEG 小窗 |
| 锁屏处理 | Guardian + AuthorizationPlugin | 无，锁屏时工具会失败 |
| 应用级策略 | 组织策略 + 内置黑名单 | 无 |
| 审批弹窗 | `createElicitation` + 4 级确认策略 | 无，依赖 harness 自身审批 |
| 私有截图路径 | `captureScreenshotWithSkyLight` | 无，只用公开 SCK |
| 每应用提示词 | `AppInstructions/*.md` | 无 |

前四项是 token 成本与稳定性优化，不影响功能正确性。
后几项是产品化能力，需要时再补。

---

## 配置

`cordis.patch.yml` 里可调：

```yaml
serverName: computer_use      # 决定工具名前缀
toolCallTimeoutMs: 180000     # 单次调用超时，截图慢时可加
```

插件自身参数（`index.js` 的 `Config`）：

| 字段 | 默认 | 说明 |
|---|---|---|
| `binary` | 包内 `bin/cua-mcp` | 覆盖二进制路径 |
| `checkPermissions` | `true` | 启动时做一次 TCC 自检 |
| `failOnPermissionError` | `false` | 缺权限时是否阻止插件激活 |

---

## 目录

```
dsh-cua/
  package.json          # dsh.bundle.patch 指向 cordis.patch.yml
  cordis.patch.yml      # 插入 mcp-computer-use 这一行
  index.js              # 插件本体：权限自检 + 路径暴露
  src/main.swift        # 原生 MCP 服务器（约 900 行）
  bin/cua-mcp           # 构建产物
  build.sh              # swiftc 构建 + 自检
```

## 重新构建

```bash
./build.sh
dsh plugin --profile web update dsh-cua   # 让 profile 拿到新二进制
```

`bin/cua-mcp` 是编译产物，换架构（arm64 ↔ x64）必须重新构建。
