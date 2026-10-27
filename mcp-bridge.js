/**
 * cua-mcp 的 stdio JSON-RPC 桥。
 *
 * 为什么不继续用 dsh-mcp-client：
 * 它构造 tools/call 时只发 name 和 arguments，不带会话上下文
 * （见 dsh-mcp-client/lib/index.js 的 callToolUncached）。
 * 于是 cua-mcp 无法知道这次操作是哪个会话发起的，
 * 实时预览就只能全局共享——切到别的会话还能看到上一个会话的目标。
 *
 * 自己起一个客户端，就能把 exec.agent.id 放进 MCP 的 params._meta，
 * 由 cua-mcp 转发给 cua-live，做到「预览只出现在发起操作的那个会话里」。
 */

import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'

/** 一次请求的超时。与原来的 toolCallTimeoutMs 保持一致。 */
const REQUEST_TIMEOUT_MS = 180_000

export class McpBridge extends EventEmitter {
  #child
  #buffer = ''
  #nextId = 1
  #pending = new Map()
  #closed = false

  constructor(binary, options = {}) {
    super()
    this.binary = binary
    this.options = options
  }

  get isRunning() {
    return this.#child !== undefined && !this.#closed
  }

  start() {
    if (this.#child) return
    this.#child = spawn(this.binary, [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    })

    this.#child.stdout.setEncoding('utf8')
    this.#child.stdout.on('data', (chunk) => this.#onData(chunk))

    this.#child.stderr.setEncoding('utf8')
    this.#child.stderr.on('data', (chunk) => {
      this.emit('stderr', chunk)
    })

    this.#child.on('exit', (code, signal) => {
      this.#closed = true
      const error = new Error(
        `cua-mcp 退出 (code=${code ?? 'null'}, signal=${signal ?? 'null'})`,
      )
      for (const [, pending] of this.#pending) pending.reject(error)
      this.#pending.clear()
      this.emit('exit', { code, signal })
    })

    this.#child.on('error', (error) => {
      this.#closed = true
      this.emit('error', error)
    })
  }

  stop() {
    if (!this.#child) return
    this.#closed = true
    try {
      this.#child.stdin.end()
      this.#child.kill()
    } catch {
      // 进程已退出
    }
    this.#child = undefined
  }

  #onData(chunk) {
    this.#buffer += chunk
    let index
    while ((index = this.#buffer.indexOf('\n')) >= 0) {
      const line = this.#buffer.slice(0, index).trim()
      this.#buffer = this.#buffer.slice(index + 1)
      if (!line) continue
      let message
      try {
        message = JSON.parse(line)
      } catch {
        continue
      }
      const id = message.id
      if (id === undefined) continue
      const pending = this.#pending.get(id)
      if (!pending) continue
      this.#pending.delete(id)
      clearTimeout(pending.timer)
      if (message.error) {
        pending.reject(new Error(message.error.message ?? 'cua-mcp 返回错误'))
      } else {
        pending.resolve(message.result)
      }
    }
  }

  #send(payload) {
    if (!this.isRunning) throw new Error('cua-mcp 未运行')
    this.#child.stdin.write(JSON.stringify(payload) + '\n')
  }

  request(method, params = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
    const id = this.#nextId++
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id)
        reject(new Error(`cua-mcp 请求超时: ${method}`))
      }, timeoutMs)
      this.#pending.set(id, { resolve, reject, timer })
      try {
        this.#send({ jsonrpc: '2.0', id, method, params })
      } catch (error) {
        this.#pending.delete(id)
        clearTimeout(timer)
        reject(error)
      }
    })
  }

  async initialize() {
    await this.request('initialize', {
      protocolVersion: '2025-06-18',
      clientInfo: { name: 'dsh-cua', version: '1.12.0' },
    })
    this.#send({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} })
  }

  async listTools() {
    const result = await this.request('tools/list', {})
    return Array.isArray(result?.tools) ? result.tools : []
  }

  /**
   * 调用一个工具。sessionId 会经 params._meta 传给 cua-mcp，
   * 用来把目标窗口归属到发起操作的会话。
   */
  async callTool(name, args, sessionId) {
    const params = { name, arguments: args ?? {} }
    if (sessionId) params._meta = { sessionId: String(sessionId) }
    const result = await this.request('tools/call', params)
    return result
  }
}

/** MCP 的 inputSchema 转成 dsh 的 parameters 形状。 */
export function toParameters(schema) {
  const properties = schema?.properties ?? {}
  const required = new Set(Array.isArray(schema?.required) ? schema.required : [])
  const parameters = {}
  for (const [key, value] of Object.entries(properties)) {
    const item = { type: value?.type ?? 'string' }
    if (value?.description) item.description = value.description
    if (Array.isArray(value?.enum)) item.enum = value.enum
    if (value?.items) item.items = value.items
    if (required.has(key)) item.required = true
    parameters[key] = item
  }
  return parameters
}

/** MCP 的 content 数组转成一段文本。 */
export function toText(result) {
  if (!result) return ''
  const content = Array.isArray(result.content) ? result.content : []
  const parts = []
  for (const block of content) {
    if (block?.type === 'text' && typeof block.text === 'string') parts.push(block.text)
  }
  return parts.join('\n')
}
