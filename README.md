<div align="center">

# dsh-cua

**让 AI 直接操作你 Mac 上的应用**

<p>
  <img src="https://img.shields.io/badge/macOS-14%2B-3b82f6?style=for-the-badge" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/arch-arm64%20%7C%20x86_64-3b82f6?style=for-the-badge" alt="架构" />
  <img src="https://img.shields.io/badge/license-MIT-3b82f6?style=for-the-badge" alt="MIT" />
</p>

<p>
  <b>dsh</b> 插件 · <b>独立 MCP</b> · <b>实时画面</b> · <b>不抢焦点</b>
</p>

</div>

---

**让 AI 真正上手操作你的 Mac，而不只是回答你。**

「把这个文件拖进访达」「帮我在备忘录记一笔」——它自己看懂窗口、自己点、自己打字，**全程就在你眼前做完**。

## ✨ 它长什么样

- 📺 **实时画面** —— 被操作的应用在对话右上角出现小窗，可点击跳转；多窗口叠在一起，点角上序号切换。
- 🎯 **目标标记** —— 屏幕上的目标控件被短暂标出，让你知道它下一步点哪里。
- 🖥️ **不抢焦点** —— 后台窗口也能打字、点按钮，你继续敲你的字，它在后台干活。

## 🚀 快速开始

### 1. 安装

```bash
dsh plugin --profile web add github:SwallOwDili/dsh-cua
```

> [!NOTE]
> 没有 dsh？见下方[「独立使用」](#独立使用不用-dsh)。想要预编译包或源码，见[「安装」](#安装)。

### 2. 授权

打开「系统设置 → 隐私与安全性」，给承载进程（终端或 DSH Desktop）勾上两项：

| 权限 | 作用 | 缺了会怎样 |
|---|---|---|
| **辅助功能** | 读界面、点元素 | 所有操作都无法执行 |
| **屏幕录制** | 截图 | 只是看不到画面，操作不受影响 |

### 3. 重启 dsh，开始用

重启后工具自动生效，直接在对话里让 AI 操作你的应用即可。

## 💡 能做什么

- 🖥️ **操作你的应用** —— 点击、输入、按键、滚动、拖拽、改值、选中文本，都是真操作。
- 👁️ **看懂界面** —— 自动识别窗口里的按钮、输入框、列表项，不靠瞎点坐标。
- 🌐 **接管浏览器** —— 用你已登录的 Chrome，后台开标签、执行脚本、截图，不干扰你正在用的窗口。
- 📜 **操作历史** —— 可选，本地记录每一步，敏感字段自动脱敏。

## 📥 安装

拿到 `dsh-cua/` 目录，两种方式任选：

```bash
# 方式一：下载预编译包（推荐，不需要 clone、不需要 Xcode）
curl -L https://github.com/SwallowDili/dsh-cua/releases/latest/download/dsh-cua-macos-universal.tar.gz | tar xz

# 方式二：克隆源码（仓库里同样带预编译二进制）
git clone https://github.com/SwallowDili/dsh-cua.git
```

解压/克隆出的 `dsh-cua/` 里，`bin/` 是 arm64 + x86_64 通用二进制。需要 macOS 14+。

## 🔌 使用方式

### 作为 dsh 插件（推荐）

```bash
dsh plugin --profile web add github:SwallOwDili/dsh-cua
```

`--profile web` 是目标 profile（默认就是 `web`，可省略）。装好后重启 dsh，
工具自动出现在模型侧，参数在「设置 → 插件配置 → cua」里调整。

自己 clone 源码开发时，也可以直接拷贝目录：

```bash
cp -R dsh-cua ~/.dsh/profiles/<profile>/node_modules/dsh-cua
```

> [!WARNING]
> 这个位置不能换——插件依赖 dsh 提供的 `schemastery`，只有放在 profile 的
> `node_modules` 下才解析得到。

### 独立使用（不用 dsh）

任何 MCP 客户端都能直接指向二进制：

```bash
<解压目录>/bin/cua-mcp
```

它是一个标准 stdio MCP 服务器，跟 dsh 没有耦合，不需要额外运行环境。
把二进制的绝对路径（在解压目录执行 `echo "$(pwd)/bin/cua-mcp"` 可得）填进
MCP 客户端的 `command` 即可。

<details>
<summary>OpenCode 接法</summary>

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
设了它，实时画面小窗才会出现在对应对话里；不设也能正常操作，只是不显示预览。

</details>

## ⚙️ 配置

在 dsh 设置页调整（`~/.dsh/dsh-cua.config.json` 是插件写出的产物，手改会在下次启动被覆盖）：

| 键 | 默认 | 说明 |
|---|---|---|
| `overlayEnabled` | `true` | 操作时在屏幕上标出目标 |
| `livePreviewEnabled` | `true` | 对话页右上角的实时画面小窗 |
| `overlayTtlSeconds` | `20` | 目标标记停留时长 |
| `scrollStepPx` | `40` | 滚动步长 |
| `maxElements` | `4000` | 单次返回的界面元素上限 |
| `syntheticActivate` | `true` | 让目标自认为前台（不夺走你的焦点） |
| `approvalMode` | `off` | 写操作前确认：`off` / `once-per-app` / `always` |
| `historyEnabled` | `true` | 记录操作历史 |
| `deniedBundleIDs` | `[]` | 禁止操作的应用 |
| `allowedBundleIDs` | `[]` | 允许列表，非空时只允许这些 |
| `browserCdpPort` | `0` | 接管浏览器时用的调试端口，`0` 为自动 |

## ⚠️ 使用须知

- **滚动**：目标在后台时不接受进程内滚轮的应用（如访达的列表），会如实报「内容没有移动」。需要前台滚动时先把窗口切到前面。点击和输入没有这个限制。
- **拖拽**：需要让目标窗口前置，这是部分 Catalyst 应用的要求。
- **锁屏**：`unlock_screen` 需要系统密码，只在明确调用时使用，不保存密码。
- **多会话并行**：多个客户端共用同一个实时画面服务，目标按会话分流，互不可见。
- **实时画面不出本机**：预览只绑 `127.0.0.1`，同网段访问不到；画面直接由本机进程推送，不经过任何外部服务。

<details>
<summary>打开未运行的应用的定位规则</summary>

`open_app` 按「英文文件名 / bundle id / 完整路径」定位，会在标准应用目录
（`/Applications`、`/System/Applications` 等）按文件名搜索。

两个例外：

- 系统应用的中文显示名（如「计算器」）是系统级本地化、不存进应用包，按中文名找不到；
- 受 Cryptexes 保护的系统应用（如 Safari）不在可遍历目录里，按文件名也找不到。

这两种情况请用 bundle id（如 `com.apple.calculator`、`com.apple.Safari`）。

</details>

## 🧠 工作原理与工具（给接入方）

`dsh-cua` 通过 macOS 的辅助功能接口读取应用的**无障碍树**——把界面上每一个按钮、
输入框、列表项，连同它们的层级、标题、当前值、可执行动作摊平成一份结构化清单。
AI 据此决定点哪里、输入什么、操作有没有生效，而不是靠猜坐标。

```
App: 访达 (pid 476)
Focused: [90] AXList <AXCollectionList> desc="图标视图" (focused) actions=[AXShowMenu]
Elements: 122
[1] AXWindow <AXStandardWindow> "dist" actions=[AXRaise]
  [2] AXSplitGroup
    [3] AXScrollArea actions=[AXScrollLeftByPage,AXScrollRightByPage]
      [4] AXOutline desc="边栏"
```

一行一个元素，前面是带编号的 ID。界面没变时 ID 跨快照稳定；界面重排时 ID 会变，
操作前先刷新一次 `get_app_state` 即可。

为省 token，默认只返回有变化的部分；截图按需附带——默认只在画面确实变了才附一张，
不要图可传 `screenshot: never`。

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

## 📄 许可

[MIT](./LICENSE)
