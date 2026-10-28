/**
 * dsh-cua — macOS Computer Use for DeepSeek Harness.
 *
 * 本插件不自己注册工具。它做四件事：
 *   1. 校验平台与二进制存在性，缺失时给出可执行的构建指令；
 *   2. 把 native 二进制的路径暴露到 ctx（便于其它插件复用）；
 *   3. 首次激活时检查辅助功能 / 屏幕录制两项 TCC 授权，未授权则明确报出；
 *   4. 向 harness 的 settings 系统注册 `cua` 命名空间，设置页「插件配置」里
 *      由 schema-form 自动生成表单。改动经 ~/.dsh/dsh-cua.config.json 落到
 *      cua-mcp 子进程（它每次工具调用前按 mtime 热读，不需要重启）。
 *
 * 工具注册由本插件自己完成（见 apply 里的 mountTools）：从 bin/cua-mcp 这个
 * stdio MCP 服务器取 tools/list，逐个注册到 ctx.tools，工具名就是 MCP 原名
 * （click / scroll / get_app_state …）。不走 @deepseek-ai/dsh-mcp-client，
 * 因为它发 tools/call 时不带会话上下文，实时预览只能全局共享——
 * 详见 mcp-bridge.js 顶部。
 *
 * 与 Codex 的 SkyComputerUseService 相比，这里没有代码签名鉴权层：
 * 二进制由 harness 自己直接拉起，AX/SCK/CGEvent 都在同一进程内完成。
 */

import { existsSync, accessSync, constants, writeFileSync } from 'node:fs'
import { McpBridge, toParameters, toContent } from './mcp-bridge.js'
import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import os from 'node:os'
import path from 'node:path'
import Schema from '@deepseek-ai/schemastery'

export const name = 'cua'

/**
 * 顶层 inject 必须留空：写成 `{ optional: [...] }` 时 cordis 4 会把 map 的每个
 * key 当成**必需服务名**去等待，`optional` 不存在 → fiber 永远 pending，
 * boot 审计报 "waiting for service: optional"，整个插件不加载。
 *
 * 但完全不声明 inject 又会有另一个坑：apply 可能在 dsh-settings 尚未 provide
 * 之前执行，`ctx.get('settings')` 拿到 undefined，命名空间就静默没注册。
 * 正解是下面 apply 里的 `ctx.inject(['settings'], ...)`：插件本体立即激活
 * （工具不受影响），settings 就绪后再注册配置命名空间；服务重建时自动重跑。
 */

export const Config = Schema.object({
  /** cua-mcp 二进制路径；留空则用包内的 bin/cua-mcp。 */
  binary: Schema.string().default(''),
  /** 启动时做一次 TCC 自检；关掉可以加快冷启动。 */
  checkPermissions: Schema.boolean().default(true),
  /** 自检失败时是否阻止插件激活。 */
  failOnPermissionError: Schema.boolean().default(false),
})

/** cua-mcp 热读的运行时配置。字段与 settings schema 一一对应。 */
export const SETTINGS_NS = 'cua'

export const RuntimeSettings = Schema.object({
  browserCdpPort: Schema.number()
    .default(0)
    .description(
      '浏览器 CDP 端口。0 表示自动读取 DevToolsActivePort（Chrome / Edge / Brave / Chromium）。' +
        '要让 browser_* 工具作用于你正在用的浏览器，需以 --remote-debugging-port 启动它。',
    ),
  browserCdpHost: Schema.string()
    .default('127.0.0.1')
    .description('CDP 主机地址，默认本机回环。'),
  overlayEnabled: Schema.boolean()
    .default(true)
    .description('是否在屏幕上显示「AI 正在操作」标记与橙色虚拟光标。'),
  livePreviewEnabled: Schema.boolean()
    .default(true)
    .description(
      '是否在对话页右上角显示实时画面小窗。与屏幕标记独立：' +
        '关掉标记仍可保留预览，反过来也一样。',
    ),
  overlayTtlSeconds: Schema.number()
    .default(20)
    .description('标记与虚拟光标在没有新动作后保留的秒数。'),
  backgroundSilence: Schema.boolean()
    .default(true)
    .description(
      '后台静默模式：点击与键入用 postToPid 定向投递、不抢焦点。' +
        '关闭后改用真实 HID 事件（能驱动 Catalyst 手势，但会被前台窗口抢走）。',
    ),
  scrollStepPx: Schema.number()
    .default(40)
    .description('滚动单步像素。过大时 Catalyst 应用会丢事件。'),
  maxElements: Schema.number()
    .default(4000)
    .description('AX 树单次快照的最大节点数。超出后截断，可调大以覆盖复杂界面。'),
  syntheticActivate: Schema.boolean()
    .default(true)
    .description(
      '合成激活：操作前把目标应用的 AXFrontmost 置位，让它「自认为」前台而系统前台不变，' +
        '用户正在用的窗口不会被抢走。' +
        '关闭后不主动激活，遇到不认事件的目标应用可能操作无效。',
    ),
  historyEnabled: Schema.boolean()
    .default(true)
    .description(
      '记录每次工具调用到 ~/.dsh/dsh-cua-history（时间、工具、目标应用、耗时、脱敏参数），' +
        '并按段聚合出 memory.md。关闭后不再写入，已有历史保留。',
    ),
  approvalMode: Schema.union(['off', 'once-per-app', 'always'])
    .default('off')
    .description(
      '操作前是否弹窗确认。off 不打扰；once-per-app 每个会话里每个应用问一次；' +
        'always 每次都问。读操作（查看界面状态、列应用）不触发。',
    ),
  deniedBundleIDs: Schema.array(Schema.string())
    .default([])
    .description('禁止操作的应用 bundleID 列表。命中即在分发层拒绝，动作不会落到目标应用。'),
  allowedBundleIDs: Schema.array(Schema.string())
    .default([])
    .description('只允许操作的应用 bundleID 列表。非空时其余应用一律拒绝，优先级高于禁止列表。'),
})

/**
 * 工具输出里图片的 canonical 形状。
 *
 * 宿主的 ImageBlock 不携带字节，只带一个 content-addressed 引用：
 *   { type: 'image', attachment: ImageAttachmentRef }
 * （见 @deepseek-ai/dsh-llm 的 types.d.ts）
 * 所以必须先经 attachment 服务落盘拿到引用，render 时才还原得出来。
 * 字段与 @deepseek-ai/dsh-tool-fs 的 IMAGE_VALUE_SCHEMA 保持一致，
 * 少一个字段宿主校验就会拒掉整个结果。
 */
const IMAGE_VALUE_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  properties: {
    attachmentId: { type: 'string', required: true },
    mediaType: {
      type: 'string',
      enum: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'],
      required: true,
    },
    bytes: { type: 'integer', required: true },
    width: { type: 'integer', required: true },
    height: { type: 'integer', required: true },
    name: { type: 'string' },
  },
}

const IMAGE_EXTENSIONS = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/webp': '.webp',
  'image/gif': '.gif',
}

function resolveBinary(config) {
  if (config.binary) return path.resolve(config.binary)
  const here = path.dirname(fileURLToPath(import.meta.url))
  return path.join(here, 'bin', 'cua-mcp')
}

/** cua-mcp 与 index.js 约定的配置落盘位置 */
export const RUNTIME_CONFIG_PATH = path.join(
  os.homedir(),
  '.dsh',
  'dsh-cua.config.json',
)

/**
 * 跑一次 --selftest，把 AX / 屏幕录制 / CGEvent 三项状态取回来。
 * 自检本身不触发授权弹窗，只读当前 TCC 状态。
 *
 * 用异步 execFile 而不是 execFileSync：自检要抓一棵真实的无障碍树、
 * 还要做 60 次路径重取验证，慢的时候几秒钟。同步跑会把宿主启动堵在这里
 * （最长 30 秒超时），而这只是「检查」，没必要挡住别人。
 */
function runSelfTest(binary) {
  return new Promise((resolve, reject) => {
    execFile(
      binary,
      ['--selftest'],
      { encoding: 'utf8', timeout: 30_000, maxBuffer: 1 << 20 },
      (error, stdout) => {
        if (error) {
          reject(error)
          return
        }
        const out = String(stdout ?? '')
        const read = (label) => {
          const line = out.split('\n').find((l) => l.startsWith(label))
          return line ? line.slice(label.length).trim() : null
        }
        resolve({
          raw: out,
          accessibility: read('AX trusted:') === 'true',
          screenRecording: read('screen capture preflight:') === 'true',
          passed: out.includes('SELFTEST PASS'),
        })
      },
    )
  })
}

/** 最近一次 flush 的配置快照，工具执行时读，避免每次重解析。 */
let currentConfig = { approvalMode: 'off' }

export async function apply(ctx, config) {
  const binary = resolveBinary(config)

  if (process.platform !== 'darwin') {
    ctx.logger?.warn?.(
      `dsh-cua: 当前平台 ${process.platform} 不受支持，仅提供 macOS 实现`,
    )
    return
  }

  if (!existsSync(binary)) {
    ctx.logger?.error?.(
      `dsh-cua: 找不到 ${binary}。在包目录执行 ./build.sh 生成二进制。`,
    )
    return
  }

  try {
    accessSync(binary, constants.X_OK)
  } catch {
    ctx.logger?.error?.(`dsh-cua: ${binary} 不可执行，检查文件权限`)
    return
  }

  // 把路径注册成 cordis 服务，其它插件可经 ctx.get('cuaBinary') 复用同一二进制。
  ctx.provide('cuaBinary', binary)

  // ---- 工具桥接：自己接 cua-mcp，而不是交给 dsh-mcp-client ----
  //
  // 原因见 mcp-bridge.js 顶部：dsh-mcp-client 构造 tools/call 时不带会话上下文，
  // cua-mcp 因此无法把操作目标归属到会话，实时预览只能全局共享——
  // 切到别的对话还能看到上一个会话的目标窗口。
  // 自己发请求就能把 exec.agent.id 放进 params._meta 带过去。
  const bridge = new McpBridge(binary)
  bridge.on('stderr', (chunk) => {
    for (const line of String(chunk).split('\n')) {
      if (line.trim()) ctx.logger?.debug?.(`dsh-cua: ${line.trim()}`)
    }
  })
  bridge.on('error', (error) => {
    ctx.logger?.error?.(`dsh-cua: cua-mcp 异常 — ${error.message}`)
  })

  ctx.effect(() => () => bridge.stop(), 'dsh-cua: cua-mcp 生命周期')

  // ---- 操作前确认（对齐 Codex 的 AppApprovalRequested / Resolved） ----
  //
  // 只读工具不打扰：查看界面、列应用、读屏幕状态都不改变任何东西。
  // 写操作按 approvalMode 决定问不问；once-per-app 在本进程内按
  // 「会话 + 应用」记一次允许，always 每次都问。
  const WRITE_TOOLS = new Set([
    'click', 'type_text', 'press_key', 'scroll', 'set_value',
    'select_text', 'paste', 'perform_secondary_action', 'open_app', 'drag',
    // unlock_screen 会全局注入登录密码（HID tap，不是定向投递），
    // browser_eval 能在已登录的浏览器里执行任意 JS——两者都是不折不扣的写操作，
    // 早先漏在这张表外面，approvalMode 对它们完全无效。
    'unlock_screen', 'browser_eval',
  ])
  const approvedScopes = new Set()
  // 不能在这里取一次快照。approval 服务若晚于插件就绪，
  // 拿到 undefined 之后再也不重试，审批就等于永久失效。
  const getApproval = () => {
    try {
      return ctx.get('approval')
    } catch {
      return undefined
    }
  }

  const askApproval = async (toolName, args, exec) => {
    const mode = currentConfig?.approvalMode ?? 'off'
    if (mode === 'off') return
    if (!WRITE_TOOLS.has(toolName)) return
    const approval = getApproval()
    if (!approval || !exec?.agent) return

    const app = typeof args?.app === 'string' ? args.app : ''
    const scopeKey = `${exec.agent.id}|${app || toolName}`
    if (mode === 'once-per-app' && approvedScopes.has(scopeKey)) return

    const reason = app
      ? `要在「${app}」上执行 ${toolName}`
      : `要执行 ${toolName}`
    const outcome = await approval.request({
      agent: exec.agent,
      toolName,
      callId: exec.callId,
      reason,
      signal: exec.signal,
    })
    if (outcome === 'allowed-once') {
      approvedScopes.add(scopeKey)
      return
    }
    const label =
      outcome === 'rejected' ? '你拒绝了这次操作' :
      outcome === 'cancelled' ? '这次操作被取消' :
      '没有可用的确认方（无人在看），按未授权处理'
    throw new Error(`dsh-cua: ${label}，${toolName} 未执行`)
  }

  // ---- 截图：从 cua-mcp 的 base64 到宿主的 ImageBlock ----
  //
  // 之前 toText 只拼 type==='text' 的块，图片在桥那一层就被丢掉了；
  // browser_screenshot 只返回图片块，于是模型收到的是空字符串。
  // 现在改成：execute 里把 JPEG 存进附件服务换一个引用，render 里还原成
  // image 块。宿主会把工具结果里的图提出来放进紧随其后的一条 user 消息，
  // 模型这才真的看得见画面。
  const getService = (serviceName) => {
    try {
      return ctx.get(serviceName)
    } catch {
      return undefined
    }
  }

  /**
   * 当前路由的模型是否声明接受图片输入。
   * 按 provider|model 缓存：查一次就够，而这是每次工具调用都要问的问题。
   * 查询失败不写缓存，下次还能重试。
   */
  const imageCapability = new Map()
  const routeAcceptsImages = async (exec) => {
    const llm = getService('llm')
    if (!llm || typeof llm.resolveModelInfo !== 'function') return false
    const routed = exec?.agent?.session?.requestHeader?.()?.config
    const provider = routed?.provider ?? exec?.agent?.options?.provider
    const model = routed?.model ?? exec?.agent?.options?.model
    if (!provider || !model) return false
    const key = `${provider}|${model}`
    if (imageCapability.has(key)) return imageCapability.get(key)
    try {
      const info = await llm.resolveModelInfo(provider, model, exec?.signal)
      const ok = Array.isArray(info?.inputModalities) && info.inputModalities.includes('image')
      imageCapability.set(key, ok)
      return ok
    } catch {
      return false
    }
  }

  /**
   * 把一张截图交给附件服务，换回可放进 ImageBlock 的引用。
   *
   * 四种情况都降级成「不带图」，而不是让整个工具调用失败：
   * 没有附件服务、模型不吃图、格式不在白名单、服务拒收（超字节/尺寸限制）。
   * 每种都在文本后补一句原因——静默丢图比丢失败更糟，模型会以为界面是空的，
   * 然后基于空白继续操作。
   */
  const persistScreenshot = async (shot, exec) => {
    if (!shot) return { image: undefined, note: '' }
    const skip = (why) => ({ image: undefined, note: `\n（截图未能附带：${why}）` })

    const attachments = getService('attachments')
    if (!attachments || typeof attachments.saveImage !== 'function') {
      return skip('宿主没有挂载附件服务')
    }
    const extension = IMAGE_EXTENSIONS[shot.mimeType]
    if (!extension) return skip(`${shot.mimeType} 不是可存储的图片格式`)
    if (!(await routeAcceptsImages(exec))) {
      return skip('当前模型不接受图片输入')
    }

    try {
      const ref = await attachments.saveImage({
        data: Buffer.from(shot.data, 'base64'),
        mediaType: shot.mimeType,
        name: `cua-${Date.now()}${extension}`,
      })
      return {
        image: {
          attachmentId: ref.attachmentId,
          mediaType: ref.mediaType,
          bytes: ref.bytes,
          width: ref.width,
          height: ref.height,
          // originalDimensions 不往上传：schema 里没声明它，
          // additionalProperties: false 会把多出来的字段判成校验失败。
        },
        note: '',
      }
    } catch (error) {
      ctx.logger?.warn?.(`dsh-cua: 截图未能存入附件服务 — ${error.message}`)
      return skip(error.message)
    }
  }

  // 工具表来自子进程的 tools/list，只有拿到它才知道挂什么。
  // 一次失败就把整个会话变成「没有任何工具」，而多数失败都是瞬时的
  // （二进制正在被 build.sh 覆盖、握手竞争）。所以给它三次退避重试。
  const disposers = []
  let mounted = false
  const mountTools = async (attempt = 1) => {
    if (mounted) return
    try {
      await bridge.ensureReady()
      const tools = await bridge.listTools()
      if (mounted) return
      for (const tool of tools) {
        disposers.push(
          ctx.tools.register({
            name: tool.name,
            description: tool.description ?? '',
            parameters: toParameters(tool.inputSchema),
            output: {
              schema: {
                type: 'object',
                additionalProperties: false,
                properties: {
                  text: { type: 'string', required: true },
                  // 可选：只有会截图的工具（get_app_state / browser_screenshot /
                  // screen_state）才带它，其余工具返回 { text } 就够。
                  image: IMAGE_VALUE_SCHEMA,
                },
                required: ['text'],
              },
              render: (_args, value) => {
                const blocks = [{ type: 'text', text: value.text }]
                // value.image 已经是 ImageAttachmentRef 的形状（brand 是恒等函数），
                // 直接当 attachment 用，不需要再转一次。
                if (value.image) blocks.push({ type: 'image', attachment: value.image })
                return blocks
              },
            },
            execute: async (args, exec) => {
              await askApproval(tool.name, args, exec)
              // exec.agent.id 就是发起这次调用的会话；后台任务可能没有 agent
              const sessionId = exec?.agent?.id
              const result = await bridge.callTool(tool.name, args, sessionId)
              const { text, images } = toContent(result)
              if (result?.isError) throw new Error(text || `${tool.name} 执行失败`)
              // 一次调用最多附一张：cua-mcp 的截图工具都只产出一张
              if (images.length > 1) {
                ctx.logger?.debug?.(
                  `dsh-cua: ${tool.name} 返回了 ${images.length} 张图，只附带第一张`,
                )
              }
              const shot = await persistScreenshot(images[0], exec)
              return shot.image
                ? { text: text + shot.note, image: shot.image }
                : { text: text + shot.note }
            },
          }),
        )
      }
      mounted = true
      ctx.logger?.info?.(`dsh-cua: 已挂载 ${tools.length} 个工具`)
    } catch (error) {
      if (attempt >= 3) {
        ctx.logger?.error?.(
          `dsh-cua: 挂载工具失败，已重试 ${attempt} 次 — ${error.message}`,
        )
        return
      }
      const wait = attempt === 1 ? 1_000 : 3_000
      ctx.logger?.warn?.(
        `dsh-cua: 挂载工具失败（第 ${attempt} 次）— ${error.message}，${wait / 1000}s 后重试`,
      )
      setTimeout(() => {
        void mountTools(attempt + 1)
      }, wait)
    }
  }
  await mountTools()

  ctx.effect(() => () => {
    for (const dispose of disposers) dispose()
  }, 'dsh-cua: 工具注销')

  // ---- 配置页：等 settings 就绪后注册命名空间，把值落盘给 cua-mcp ----
  // 用 ctx.inject 而不是顶层 inject：插件本体不等服务，工具照常可用。
  ctx.inject(['settings'], (ctx) => {
    const settings = ctx.settings
    if (!settings || typeof settings.register !== 'function') return
    let lastWritten = null
    try {
      const scope = settings.register(SETTINGS_NS, RuntimeSettings, { base: {} })
      const flush = () => {
        // schemastery 解析后的值 = 默认值 + 用户文档覆盖
        const value = RuntimeSettings(scope.get() ?? {})
        currentConfig = value
        const json = JSON.stringify(value, null, 2) + '\n'
        if (json === lastWritten) return
        lastWritten = json
        writeFileSync(RUNTIME_CONFIG_PATH, json, { mode: 0o600 })
      }
      flush()
      ctx.effect(() => {
        const stop = scope.watch(flush)
        return () => {
          if (typeof stop === 'function') stop()
        }
      })
      ctx.logger?.info?.(
        `dsh-cua: 设置命名空间 "${SETTINGS_NS}" 已注册，配置页可见；` +
          `运行时配置写入 ${RUNTIME_CONFIG_PATH}`,
      )
    } catch (error) {
      ctx.logger?.warn?.(`dsh-cua: 注册配置命名空间失败 — ${error.message}`)
    }
  })

  if (!config.checkPermissions) {
    ctx.logger?.info?.(`dsh-cua: 已就绪 (${binary})`)
    return
  }

  let result
  try {
    result = await runSelfTest(binary)
  } catch (error) {
    const message = `dsh-cua: 自检执行失败 — ${error.message}`
    if (config.failOnPermissionError) throw new Error(message)
    ctx.logger?.warn?.(message)
    return
  }

  const missing = []
  if (!result.accessibility) missing.push('辅助功能 (Accessibility)')
  if (!result.screenRecording) missing.push('屏幕录制 (Screen Recording)')

  if (missing.length > 0) {
    const message =
      `dsh-cua: 缺少授权 — ${missing.join('、')}。` +
      `请在 系统设置 → 隐私与安全性 中为承载 harness 的进程（终端或 DSH Desktop）勾选对应项，` +
      `然后重启 harness。AX 工具在未授权时会失败，截图会不可用。`
    if (config.failOnPermissionError) throw new Error(message)
    ctx.logger?.warn?.(message)
    return
  }

  ctx.logger?.info?.(
    `dsh-cua: 已就绪 (${binary})，辅助功能与屏幕录制均已授权`,
  )
}
