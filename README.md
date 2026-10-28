# dsh-cua

macOS 上的 Computer Use：让模型直接看见并操作你的桌面应用。

不依赖辅助窗口、不接管鼠标键盘。模型主要拿到的是应用的无障碍树——
一份结构化的可用元素清单，靠它决定点哪里、输入什么、操作有没有生效。
截图是按需附带的：默认只在画面确实变了才附一张，随工具结果一起交给模型
（存进宿主的附件服务，按引用传递）；不要图可以传 `screenshot: never`。

```
App: 访达 (pid 476)
Focused: [90] AXList <AXCollectionList> desc="图标视图" (focused) actions=[AXShowMenu]
Elements: 122
[1] AXWindow <AXStandardWindow> "dist" actions=[AXRaise]
  [2] AXSplitGroup
    [3] AXScrollArea actions=[AXScrollLeftByPage,AXScrollRightByPage]
      [4] AXOutline desc="边栏"
```

一行一个元素，前面是跨快照稳定的 ID。模型据此定位，不靠猜坐标。

## 它做什么

- **读界面**：把应用的可交互元素连层级一起摊平，标注标题、值、状态、可用动作。
- **操作**：点击、输入、按键、滚动、拖拽、改值、选中文本，都直接投递给目标进程。
- **不抢焦点**：给后台窗口打字、点按钮时不会把你的键盘输入打断；滚动失败会明说，不会擅自把窗口拽到前台。
- **省 token**：默认返回增量，只报变化的部分。截图是按需的，不是每次都传图。
- **实时画面**：正在被操作的应用在对话右上角出一个小窗，可点击跳转；多个窗口同时操作时叠在一起，点角上的序号切换看哪个。
- **历史**：可选的本地操作记录，敏感字段自动脱敏，附一份记忆文件供后续参考。
- **浏览器**：可接管已登录的 Chrome，后台开标签、执行脚本、截图，不干扰你正在用的窗口。

## 安装

一条命令，不需要 clone，不需要 Xcode：

```bash
curl -L https://github.com/SwallowDili/dsh-cua/releases/latest/download/dsh-cua-macos-universal.tar.gz | tar xz
```

解压出 `dsh-cua/`，里面的 `bin/` 已经是 arm64 + x86_64 通用二进制。
下面所有命令里的 `<解压目录>` 就指这个路径。

也可以从源码拿：

```bash
git clone https://github.com/SwallowDili/dsh-cua.git
```

两种方式拿到的内容相同，仓库里同样带预编译二进制。

需要 macOS 14+。

### 作为 dsh 插件

必须放进 dsh profile 的 `node_modules` 下：

```bash
cp -R dsh-cua ~/.dsh/profiles/<profile>/node_modules/dsh-cua
```

`<profile>` 是你的 profile 名（默认 `web`）。

**位置不能换。** 插件的 Node 部分依赖 `@deepseek-ai/schemastery`
（由 dsh 自身提供，包里不带），只有放在 profile 的 `node_modules` 下才解析得到。
放到别处会在加载时报：

```
ERR_MODULE_NOT_FOUND: Cannot find package '@deepseek-ai/schemastery'
```

重启 dsh 后，工具会出现在模型侧，参数在「设置 → 插件配置 → cua」里调整。

独立 MCP 模式没有这个限制，二进制不依赖任何 Node 包。

### 作为独立 MCP 服务器

不用 dsh，任何 MCP 客户端直接指向二进制：

```bash
<解压目录>/bin/cua-mcp
```

它是个 stdio 服务器，不需要额外的运行环境。

## 授权

首次使用前要给承载进程（终端或 DSH Desktop）两项系统权限：

- **辅助功能**：读界面、点元素。没有它所有工具都会失败。
- **屏幕录制**：截图。没有它截图不可用，其余功能正常。

在「系统设置 → 隐私与安全性」里勾选后重启宿主进程。插件启动时会自检并明确报出缺哪一项。

## 对接方式

`bin/cua-mcp` 是标准 stdio MCP 服务器，跟 dsh 没有耦合，任何 MCP 客户端都能直接接。

### dsh 插件（推荐）

装上即用，工具自动出现在模型侧。插件名 `cua`，配置在设置页。

### 任意 MCP 客户端

先拿到二进制的绝对路径（在解压出来的目录里执行）：

```bash
echo "$(pwd)/bin/cua-mcp"
```

把输出填进 `command`。下面两处 `"/Users/you/code/dsh-cua"` 都是示例，换成你的实际路径：

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

`timeout` 要调大，默认 30 秒会把正常操作腰斩。`CUA_SESSION` 决定实时画面归谁——
不设也能用，只是预览不会出现在任何对话里。

授权是独立的一份：从哪个终端启动 OpenCode，就给那个终端勾选辅助功能与屏幕录制。

## 工具

| 工具 | 作用 |
|---|---|
| `list_apps` | 列出运行中的图形应用 |
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

在 dsh 设置页调整。`~/.dsh/dsh-cua.config.json` 只是插件写出的产物，手改会在下次启动被设置页的值覆盖：

| 键 | 默认 | 说明 |
|---|---|---|
| `overlayEnabled` | `true` | 操作时在屏幕上标出目标 |
| `livePreviewEnabled` | `true` | 对话页右上角的实时画面小窗，与上一条互不影响 |
| `overlayTtlSeconds` | `20` | 标记停留时长 |
| `backgroundSilence` | `true` | 后台操作不抢焦点 |
| `scrollStepPx` | `40` | 滚动步长 |
| `maxElements` | `4000` | 单次返回的元素上限 |
| `syntheticActivate` | `true` | 让目标自认为前台（不夺走你的焦点） |
| `approvalMode` | `off` | 写操作前确认：`off` / `once-per-app` / `always` |
| `historyEnabled` | `true` | 记录操作历史 |
| `deniedBundleIDs` | `[]` | 禁止操作的应用 |
| `allowedBundleIDs` | `[]` | 允许列表，非空时只允许这些 |
| `browserCdpPort` | `0` | 接管浏览器时用的调试端口，`0` 为自动 |

## 边界

需要你知道的几件事：

- **滚动**：目标在后台时不接受进程内滚轮的应用（如访达的列表），会如实报「内容没有移动」。需要前台滚动时先把窗口切到前面。点击和输入没有这个限制。
- **拖拽**：仍走全局事件并会让目标前置，这是部分 Catalyst 应用的要求。
- **锁屏**：`unlock_screen` 需要系统密码，只在明确调用时使用，不保存密码。
- **并行使用**：多个客户端共用同一个实时画面服务，目标按会话分流，互不可见。
- **实时画面不出本机**：预览用的 18901 端口只绑 `127.0.0.1`，同网段访问不到；
  画面直接由本机进程推到浏览器，不经过任何外部服务。

## 许可

MIT
