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
 * 工具注册由 cordis.patch.yml 插入的 @deepseek-ai/dsh-mcp-client 完成：
 * 它把 bin/cua-mcp 这个 stdio MCP 服务器上的工具挂到 ctx.tools 上，
 * 模型看到的名字是 mcp__computer_use__<tool>。
 *
 * 与 Codex 的 SkyComputerUseService 相比，这里没有代码签名鉴权层：
 * 二进制由 harness 自己直接拉起，AX/SCK/CGEvent 都在同一进程内完成。
 */

import { existsSync, accessSync, constants, writeFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
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
  deniedBundleIDs: Schema.array(Schema.string())
    .default([])
    .description('禁止操作的应用 bundleID 列表。命中即在分发层拒绝，动作不会落到目标应用。'),
  allowedBundleIDs: Schema.array(Schema.string())
    .default([])
    .description('只允许操作的应用 bundleID 列表。非空时其余应用一律拒绝，优先级高于禁止列表。'),
})

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
 */
function runSelfTest(binary) {
  const out = execFileSync(binary, ['--selftest'], {
    encoding: 'utf8',
    timeout: 30_000,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const read = (label) => {
    const line = out.split('\n').find((l) => l.startsWith(label))
    return line ? line.slice(label.length).trim() : null
  }
  return {
    raw: out,
    accessibility: read('AX trusted:') === 'true',
    screenRecording: read('screen capture preflight:') === 'true',
    passed: out.includes('SELFTEST PASS'),
  }
}

export function apply(ctx, config) {
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
    result = runSelfTest(binary)
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
