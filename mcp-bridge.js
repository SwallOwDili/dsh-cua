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
  #starting = null
  /** 子进程是否已完成 MCP 握手。进程活着 ≠ 握过手，两者要分开记。 */
  #initialized = false

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

    // 子进程退出后再往 stdin 写会 EPIPE。没人接住这个 error 事件，
    // Node 会把它升级成未捕获异常，直接带走宿主进程。
    this.#child.stdin.on('error', (error) => {
      this.#closed = true
      this.#initialized = false
      // 同样要清引用，否则下一次 ensureReady 会因为 start() 里的
      // “已存在 child”提前返回，再也不重新拉起。
      this.#child = undefined
      this.emit('error', error)
    })

    this.#child.stderr.setEncoding('utf8')
    this.#child.stderr.on('data', (chunk) => {
      this.emit('stderr', chunk)
    })

    this.#child.on('exit', (code, signal) => {
      this.#closed = true
      this.#initialized = false
      // 必须清掉引用。否则 ensureReady 里 start() 会因为
      // “已经有一个 child”直接返回，永远不重新 spawn，
      // 而每次调用都会挂到 180 秒超时——全部工具瘫痪到宿主重启。
      this.#child = undefined
      const error = new Error(
        `cua-mcp 退出 (code=${code ?? 'null'}, signal=${signal ?? 'null'})`,
      )
      for (const [, pending] of this.#pending) pending.reject(error)
      this.#pending.clear()
      this.emit('exit', { code, signal })
    })

    this.#child.on('error', (error) => {
      this.#closed = true
      this.#initialized = false
      this.#child = undefined
      this.emit('error', error)
    })
  }

  stop() {
    if (!this.#child) return
    this.#closed = true
    this.#initialized = false
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
    // 管道已死时 write 不会同步抛，只会异步给个 EPIPE——请求就会一直
    // 挂到 180 秒超时。这里同步判死，让调用方立刻拿到错误，
    // 下一次调用再由 ensureReady 重新拉起。
    if (this.#child.exitCode !== null || this.#child.signalCode !== null) {
      this.#closed = true
      this.#child = undefined
      throw new Error('cua-mcp 已退出')
    }
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

  /**
   * 保证子进程活着**并且**已握手。
   *
   * 只判 isRunning 是不够的：调用方先 start() 再 initialize() 时，
   * 进程已经在跑但握手还没完成，ensureReady 会误判成就绪；
   * 反过来进程活着但握手失败时，也永远不会重试。
   * 二进制被重新构建后，旧进程跑的还是旧代码，而它是常驻的、
   * 不会自己换新——所以调用前兜底重启一次。
   */
  async ensureReady() {
    if (this.isRunning && this.#initialized) return
    // 并发调用只允许一个 initialize。MCP 规定握手一次，
    // 两个会话同时发起工具调用时重复握手会让子进程状态错乱。
    if (!this.#starting) {
      this.#starting = (async () => {
        this.#closed = false
        this.#buffer = ''
        this.start()
        await this.initialize()
      })()
    }
    try {
      await this.#starting
    } catch (error) {
      // 握手失败就别留着半死的子进程
      this.stop()
      throw error
    } finally {
      this.#starting = null
    }
  }

  async initialize() {
    await this.request('initialize', {
      protocolVersion: '2025-06-18',
      clientInfo: { name: 'dsh-cua', version: '1.12.0' },
    })
    this.#send({ jsonrpc: '2.0', method: 'notifications/initialized', params: {} })
    this.#initialized = true
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
    await this.ensureReady()
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

/**
 * 把 MCP 的 content 数组拆成文本与图片两部分。
 *
 * 拆分而不是只管文本，是因为截图真的能送到模型眼前——宿主对工具结果里的
 * image 块有专门搬运：provider adapter 会把它从纯文本的 tool 消息里提出来，
 * 放到紧随其后的一条 user 消息（dsh-llm-deepseek/serialize 的
 * 「Tool-result images follow their string-only tool messages」）。
 * 之前这里只 join 文本，等于把图在桥这一层就丢了。
 *
 * 桥自己不做落盘：图片字节怎么存是宿主附件服务的事，这里只负责原样交出去。
 */
export function toContent(result) {
  const content = Array.isArray(result?.content) ? result.content : []
  const texts = []
  const images = []
  for (const block of content) {
    if (block?.type === 'text' && typeof block.text === 'string') {
      texts.push(block.text)
    } else if (block?.type === 'image' && typeof block.data === 'string' && block.data) {
      // MCP 的字段名是 mimeType；缺省按 JPEG 猜（cua-mcp 只产出这一种）
      images.push({ data: block.data, mimeType: block.mimeType || 'image/jpeg' })
    }
  }
  return { text: texts.join('\n'), images }
}

/** MCP 的 content 数组转成一段文本。图片由 {@link toContent} 交给调用方。 */
export function toText(result) {
  return toContent(result).text
}
