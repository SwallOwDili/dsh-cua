# dsh-cua

macOS 桌面操作助手：让 AI 直接看见并操作你屏幕上的应用。

它把每个正在运行的应用翻译成一份结构化清单——界面上每一个按钮、输入框、列表项，
连同它们的层级、标题、当前值、可执行动作一起摊平，AI 据此决定点哪里、输入什么、
操作有没有生效。不需要辅助窗口，不接管你的鼠标键盘。

```
App: 访达 (pid 476)
Focused: [90] AXList <AXCollectionList> desc="图标视图" (focused) actions=[AXShowMenu]
Elements: 122
[1] AXWindow <AXStandardWindow> "dist" actions=[AXRaise]
  [2] AXSplitGroup
    [3] AXScrollArea actions=[AXScrollLeftByPage,AXScrollRightByPage]
      [4] AXOutline desc="边栏"
```

一行一个元素，前面是带编号的 ID。AI 按 ID 定位，不猜坐标。界面没变时 ID 跨快照稳定；
界面重排时 ID 会变，操作前先刷新一次 `get_app_state` 即可。

## 能做什么

- **读界面**：把应用的可交互元素连层级一起摊平，标注标题、值、状态、可用动作。
- **操作**：点击、输入、按键、滚动、拖拽、改值、选中文本，直接作用于目标应用。
- **不抢焦点**：给后台窗口打字、点按钮，不会打断你正在做的事；滚动受限时会明确说明，不会擅自把窗口拽到前台。
- **省 token**：默认只返回有变化的部分。截图按需附带——默认只在画面确实变了才附一张；不要图可传 `screenshot: never`。
- **实时画面**：正在被操作的应用，在对话右上角出现一个小窗，可点击跳转；同时操作多个窗口时叠在一起，点角上的序号切换。
- **历史**：可选的本地操作记录，敏感字段自动脱敏，附一份记忆文件供后续参考。
- **浏览器**：可接管已登录的 Chrome，在后台开标签、执行脚本、截图，不干扰你正在用的窗口。

## 安装

一条命令，不需要 clone，不需要 Xcode：

```bash
curl -L https://github.com/SwallowDili/dsh-cua/releases/latest/download/dsh-cua-macos-universal.tar.gz | tar xz
```

解压出 `dsh-cua/`，里面的 `bin/` 是 arm64 + x86_64 通用二进制。下文所有命令里的
`<解压目录>` 都指这个路径。

也可以从源码获取：

```bash
git clone https://github.com/SwallowDili/dsh-cua.git
```

两种方式拿到的内容相同，仓库里同样带预编译二进制。

需要 macOS 14+。

### 作为 dsh 插件

放进 dsh profile 的 `node_modules` 下：

```bash
cp -R dsh-cua ~/.dsh/profiles/<profile>/node_modules/dsh-cua
```

`<profile>` 是你的 profile 名（默认 `web`）。这个位置不能换——插件依赖 dsh 提供的
`schemastery`，只有放在 profile 的 `node_modules` 下才解析得到。

重启 dsh 后，工具会出现在模型侧，参数在「设置 → 插件配置 → cua」里调整。

### 作为独立 MCP 服务器

不用 dsh，任何 MCP 客户端直接指向二进制即可：

```bash
<解压目录>/bin/cua-mcp
```

它是个 stdio 服务器，不需要额外的运行环境。

## 授权

首次使用前，给承载进程（终端或 DSH Desktop）两项系统权限：

- **辅助功能**：读界面、点元素。没有它所有工具都会失败。
- **屏幕录制**：截图。没有它截图不可用，其余功能正常。

在「系统设置 → 隐私与安全性」里勾选后重启宿主进程。插件启动时会自检并明确报出缺哪一项。

## 对接方式

`bin/cua-mcp` 是标准 stdio MCP 服务器，跟 dsh 没有耦合，任何 MCP 客户端都能直接接。

### dsh 插件（推荐）

装上即用，工具自动出现在模型侧。插件名 `cua`，配置在设置页。走插件链路时，操作会自动归属到当前会话，实时画面小窗只出现在对应的对话里。

### 任意 MCP 客户端

先拿到二进制的绝对路径（在解压目录里执行）：

```bash
echo "$(pwd)/bin/cua-mcp"
```

把输出填进 `command`。下面 `"/Users/you/code/dsh-cua"` 是示例，换成你的实际路径：

```json
{
  "mcpServers": {
    "computer-use": {
      "command": "/Users/you/code/dsh-cua/bin/cua-mcp"
    }
  }
}
```

装了 dsh 插件、想用 profile 里那份的话，路径是
`~/.dsh/profiles/<profile>/node_modules/dsh-cua/bin/cua-mcp`。

### OpenCode

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "computer-use": {
      "type": "local",
      "command": ["/Users/you/code/dsh-cua/bin/cua-mcp"],
      "enabled": true,
      "timeout": 120000,
      "environment": { "CUA_SESSION": "opencode" }
    }
  }
}
```

`timeout` 建议调大，默认 30 秒会把正常操作腰斩。`CUA_SESSION` 声明这次操作归属哪个会话——
设了它，实时画面小窗才会出现在对应对话里；不设也能正常操作，只是不会显示预览。

授权是独立的一份：从哪个终端启动 OpenCode，就给那个终端勾选辅助功能与屏幕录制。

## 工具

| 工具 | 作用 |
|---|---|
| `list_apps` | 列出运行中的图形应用（名称、bundle id、pid，`*` 标前台） |
| `screen_state` | 返回 `locked` / `unlocked` |
| `unlock_screen` | 唤醒屏幕并按需注入密码解锁，密码不落盘 |
| `get_app_state` | 无障碍树文本 + 按需截图，默认增量 |
| `click` | 点元素中心或坐标，支持双击、右键 |
| `type_text` | Unicode 直接注入，不走剪贴板 |
| `press_key` | 按键或组合键，如 `return`、`cmd+c`、`shift+tab` |
| `scroll` | 按页滚动，可指定元素或坐标 |
| `set_value` | 直接写元素 value |
| `select_text` | 在文本元素里选中子串 |
| `paste` | 走剪贴板并还原用户原有内容 |
| `perform_secondary_action` | AXPress / AXShowMenu / AXConfirm / AXRaise |
| `drag` | 拖拽 |
| `open_app` | 打开或激活应用，按名称、bundle id 或路径 |
| `browser_tabs` | 列出浏览器标签页 |
| `browser_open` | 后台打开标签页，可用已登录会话 |
| `browser_eval` | 在页面里执行脚本 |
| `browser_screenshot` | 截取页面 |
| `history` | 读操作历史、写记忆文件、开关记录 |

## 配置

在 dsh 设置页调整。`~/.dsh/dsh-cua.config.json` 是插件写出的产物，手改会在下次启动被设置页覆盖：

| 键 | 默认 | 说明 |
|---|---|---|
| `overlayEnabled` | `true` | 操作时在屏幕上标出目标 |
| `livePreviewEnabled` | `true` | 对话页右上角的实时画面小窗，与上一条互不影响 |
| `overlayTtlSeconds` | `20` | 标记停留时长 |
| `scrollStepPx` | `40` | 滚动步长 |
| `maxElements` | `4000` | 单次返回的元素上限 |
| `syntheticActivate` | `true` | 让目标自认为前台（不夺走你的焦点） |
| `approvalMode` | `off` | 写操作前确认：`off` / `once-per-app` / `always` |
| `historyEnabled` | `true` | 记录操作历史 |
| `deniedBundleIDs` | `[]` | 禁止操作的应用 |
| `allowedBundleIDs` | `[]` | 允许列表，非空时只允许这些 |
| `browserCdpPort` | `0` | 接管浏览器时用的调试端口，`0` 为自动 |

## 使用须知

- **滚动**：目标在后台时不接受进程内滚轮的应用（如访达的列表），会如实报「内容没有移动」。需要前台滚动时先把窗口切到前面。点击和输入没有这个限制。
- **拖拽**：需要让目标窗口前置，这是部分 Catalyst 应用的要求。
- **锁屏**：`unlock_screen` 需要系统密码，只在明确调用时使用，不保存密码。
- **多会话并行**：多个客户端共用同一个实时画面服务，目标按会话分流，互不可见。
- **实时画面不出本机**：预览只绑 `127.0.0.1`，同网段访问不到；画面直接由本机进程推送，不经过任何外部服务。
- **打开未运行的应用**：`open_app` 按「英文文件名 / bundle id / 完整路径」定位，会在标准应用目录（`/Applications`、`/System/Applications` 等）按文件名搜索。
  两个例外：系统应用的中文显示名（如「计算器」）是系统级本地化、不存进应用包，按中文名找不到；
  受 Cryptexes 保护的系统应用（如 Safari）不在可遍历目录里，按文件名也找不到。
  这两种情况请用 bundle id（如 `com.apple.calculator`、`com.apple.Safari`）。

## 许可

MIT
