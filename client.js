/**
 * dsh-cua — 浏览器半（配置卡片）。
 *
 * dsh 的「插件配置」页渲染的是两份账本的交集：Host 提供的 settings 命名空间
 * + client 端注册到 `settings.plugin.item` 的卡片。index.js 只做完前者，
 * 所以这里补上认领 `cua` 命名空间的卡片，否则命名空间存在但没有任何界面。
 *
 * 运行形态：前端模块加载器执行本文件时只注册 factory，
 * 依赖（react / slots / settingsScope）在物化时由 shell 注入，
 * 因此这里不打包任何东西，也不 import 宿主私有组件。
 */

window.__ModuleLoader__.load({
  id: 'dsh-cua',
  factory: (require) => {
    var module = { exports: {} }
    var exports = module.exports
    Object.defineProperty(exports, Symbol.toStringTag, { value: 'Module' })

    const React = require('react')
    const h = React.createElement

    const NS = 'cua'

    /** 字段元数据：与 index.js 的 RuntimeSettings 一一对应。 */
    const FIELDS = [
      {
        field: 'browserCdpPort',
        kind: 'number',
        label: '浏览器 CDP 端口',
        hint: '0 = 自动读取 DevToolsActivePort。要操作后台标签页，需以 --remote-debugging-port=9222 启动浏览器后填 9222。',
      },
      {
        field: 'overlayEnabled',
        kind: 'boolean',
        label: '屏幕标记与虚拟光标',
        hint: '关闭后 AI 操作不再在窗口左上角显示胶囊标记和橙色光标。',
      },
      {
        field: 'livePreviewEnabled',
        kind: 'boolean',
        label: '对话页实时画面',
        hint: '右上角的小窗。与屏幕标记互不影响，可单独关闭。',
      },
      {
        field: 'overlayTtlSeconds',
        kind: 'number',
        label: '标记保留秒数',
        hint: '没有新动作后，标记与光标在屏幕上保留多久。',
      },
      {
        field: 'scrollStepPx',
        kind: 'number',
        label: '滚动单步像素',
        hint: '过大时 Catalyst 应用（如 Infuse）会丢事件。',
      },
      {
        field: 'maxElements',
        kind: 'number',
        label: 'AX 快照节点上限',
        hint: '界面复杂时快照会被截断，可调大。',
      },
      {
        field: 'syntheticActivate',
        kind: 'boolean',
        label: '合成激活目标应用',
        hint: '操作前让目标应用「自认为」前台，但不抢走你正在用的窗口。',
      },
      {
        field: 'historyEnabled',
        kind: 'boolean',
        label: '记录操作历史',
        hint: '写入 ~/.dsh/dsh-cua-history；参数脱敏，密码与输入内容不落盘。',
      },
      {
        field: 'deniedBundleIDs',
        kind: 'list',
        label: '禁止操作的应用',
        hint: 'bundleID 列表，逗号分隔。命中即在分发层拒绝，例如 com.apple.finder',
      },
      {
        field: 'allowedBundleIDs',
        kind: 'list',
        label: '只允许操作的应用',
        hint: 'bundleID 列表，逗号分隔。非空时其余应用一律拒绝，优先级高于禁止列表。',
      },
    ]

    /** React useSyncExternalStore 契约的快照容器。 */
    function createStore(initial) {
      let value = initial
      const listeners = new Set()
      return {
        getSnapshot: () => value,
        subscribe: (listener) => {
          listeners.add(listener)
          return () => listeners.delete(listener)
        },
        set(next) {
          value = next
          for (const listener of listeners) listener()
        },
      }
    }

    const SPECS = {
      number: {
        // 草稿来自输入框是字符串，来自 settings 是 number，两者都要能显示
        format: (value) =>
          typeof value === 'number' ? String(value) : typeof value === 'string' ? value : '',
        parse: (input) => {
          if (typeof input === 'string' && input.trim() === '') return { kind: 'clear' }
          const parsed = typeof input === 'number' ? input : Number(String(input).trim())
          return Number.isFinite(parsed) ? { kind: 'set', value: parsed } : undefined
        },
      },
      text: {
        format: (value) => (typeof value === 'string' ? value : value == null ? '' : String(value)),
        parse: (input) => {
          const text = String(input ?? '').trim()
          return text === '' ? { kind: 'clear' } : { kind: 'set', value: text }
        },
      },
      boolean: {
        format: (value) => value === true,
        parse: (input) => ({ kind: 'set', value: input === true }),
      },
      list: {
        // 数组用逗号分隔的一行文本编辑：bundleID 列表不值得为它做增删控件
        format: (value) =>
          Array.isArray(value) ? value.join(', ') : typeof value === 'string' ? value : '',
        parse: (input) => {
          const text = String(input ?? '').trim()
          if (text === '') return { kind: 'set', value: [] }
          const items = text
            .split(/[,，\s]+/)
            .map((s) => s.trim())
            .filter(Boolean)
          return { kind: 'set', value: items }
        },
      },
    }

    /**
     * 暂存编辑并写回 settings 的一段命名空间。
     * 行为对齐宿主 CardForm：只有 Host 确认落盘后才清空暂存，
     * 保存失败保留草稿，避免用户重打。
     */
    var CardForm = class {
      constructor(scope, fields) {
        this.scope = scope
        this.specs = new Map(fields.map((item) => [item.field, SPECS[item.kind]]))
        this.staged = new Map()
        this.listeners = new Set()
        this.saving = false
        this.failed = false
        this.disposals = [scope.subscribe(() => this.publish())]
      }

      bind(project) {
        const store = createStore(project())
        this.listeners.add(() => store.set(project()))
        return store
      }

      publish() {
        for (const listener of this.listeners) listener()
      }

      dispose() {
        for (const off of this.disposals) {
          if (typeof off === 'function') off()
        }
        this.listeners.clear()
      }

      snapshotOf() {
        return this.scope.getSnapshot()
      }

      sectionValue(field) {
        return this.snapshotOf().value?.[field]
      }

      stored(field) {
        const user = this.snapshotOf().user
        return user !== undefined && Object.hasOwn(user, field)
      }

      specOf(field) {
        const spec = this.specs.get(field)
        if (spec === undefined) throw new Error(`dsh-cua: 未知字段 ${field}`)
        return spec
      }

      shell() {
        const snapshot = this.snapshotOf()
        const plan = this.plan()
        return {
          available: snapshot.status === 'ready',
          writable: snapshot.writable === true,
          dirty: plan.length > 0,
          invalid: plan.some((item) => item.run === undefined),
          saving: this.saving,
          failed: this.failed,
        }
      }

      field(field) {
        const spec = this.specOf(field)
        const staged = this.staged.get(field)
        if (staged === undefined) {
          return {
            value: spec.format(this.sectionValue(field)),
            overridden: this.stored(field),
            invalid: false,
          }
        }
        if (staged.clear) {
          return {
            value: spec.format(this.sectionValue(field)),
            overridden: this.stored(field),
            invalid: false,
          }
        }
        const write = spec.parse(staged.value)
        return {
          value: spec.format(staged.value),
          overridden: write !== undefined && write.kind === 'set',
          invalid: write === undefined,
        }
      }

      actions() {
        return {
          edit: (field, value) => {
            this.staged.set(field, { value, clear: false })
            this.failed = false
            this.publish()
          },
          resetField: (field) => {
            this.staged.set(field, { value: undefined, clear: true })
            this.failed = false
            this.publish()
          },
          save: () => {
            void this.save()
          },
          discard: () => {
            if (this.staged.size === 0 && !this.failed) return
            this.staged.clear()
            this.failed = false
            this.publish()
          },
        }
      }

      plan() {
        const plan = []
        for (const [field, staged] of this.staged) {
          const spec = this.specOf(field)
          if (staged.clear) {
            if (this.stored(field)) {
              plan.push({ field, run: () => this.clear(field) })
            }
            continue
          }
          const write = spec.parse(staged.value)
          if (write === undefined) {
            plan.push({ field, run: undefined })
            continue
          }
          if (write.kind === 'clear') {
            if (this.stored(field)) {
              plan.push({ field, run: () => this.clear(field) })
            }
            continue
          }
          if (this.stored(field) && this.sectionValue(field) === write.value) continue
          plan.push({ field, run: () => this.write(field, write.value) })
        }
        return plan
      }

      async clear(field) {
        await this.scope.unset(field)
        return !this.stored(field)
      }

      async write(field, value) {
        await this.scope.set(field, value)
        return this.snapshotOf().user?.[field] === value
      }

      async save() {
        const plan = this.plan()
        const writes = plan.flatMap((item) => (item.run === undefined ? [] : [item.run]))
        if (plan.length === 0 || this.saving || writes.length !== plan.length) return
        this.saving = true
        this.failed = false
        this.publish()
        let landed = true
        for (const write of writes) {
          landed = (await write()) && landed
        }
        if (landed) this.staged.clear()
        this.saving = false
        this.failed = !landed
        this.publish()
      }

      inject() {
        return {
          hooks: { cuaCard: this.store },
          ...this.actions(),
        }
      }
    }


    // ---- 实时画面小窗（对话页右上角）----
    //
    // 数据来自 cua-live 的 MJPEG 流。跨端口的 <img> 不受 CORS 约束，
    // 所以这里不需要任何票据；status 轮询只用来决定显示还是隐藏。

    const LIVE_BASE = 'http://127.0.0.1:18901'
    /** 预览卡宽度（CSS px）。抓帧宽度是它的两倍，见 live/main.swift 的 previewWidth。 */
    const CARD_W = 132

    const liveCss = {
      // 一条主窗，背后错位露出几张的边
      stack: {
        display: 'flex',
        alignItems: 'center',
      },
      // 叠放容器：按最大尺寸留位，背景卡绝对定位错位叠在主窗下面
      deck: {
        position: 'relative',
        paddingRight: '6px',
        paddingBottom: '6px',
        // 主窗是 inline-flex，作为 inline 级元素会留下基线下沿的几像素空隙，
        // 让主窗相对背后的卡看起来偏上。压掉行高就对齐了。
        lineHeight: '0',
      },
      backCard: {
        position: 'absolute',
        top: 0,
        left: 0,
        borderRadius: '8px',
        border: '0.5px solid var(--dsw-alias-border-l4, #dcdcdc)',
        background: 'var(--dsw-alias-bg-layer-2, #fff)',
        boxShadow: '0 1px 4px rgba(0,0,0,0.10)',
      },
      switcher: {
        position: 'absolute',
        right: '6px',
        top: '6px',
        padding: '1px 5px',
        borderRadius: '4px',
        background: 'rgba(0,0,0,0.55)',
        color: '#fff',
        fontSize: '10px',
        lineHeight: '1.5',
        cursor: 'pointer',
        userSelect: 'none',
      },
      wrap: {
        position: 'relative',
        display: 'inline-flex',
        alignItems: 'center',
        cursor: 'pointer',
      },
      frame: {
        width: CARD_W + 'px',
        borderRadius: '8px',
        border: '0.5px solid var(--dsw-alias-border-l4, #dcdcdc)',
        background: 'var(--dsw-alias-bg-layer-2, #fff)',
        display: 'block',
        boxShadow: '0 2px 8px rgba(0,0,0,0.12)',
      },
      tag: {
        position: 'absolute',
        left: '6px',
        bottom: '6px',
        padding: '1px 6px',
        borderRadius: '4px',
        background: 'rgba(0,0,0,0.55)',
        color: '#fff',
        fontSize: '10px',
        lineHeight: '1.5',
        maxWidth: CARD_W - 24 + 'px',
        overflow: 'hidden',
        textOverflow: 'ellipsis',
        whiteSpace: 'nowrap',
      },
      checker: {
        borderRadius: '8px',
        border: '0.5px solid var(--dsw-alias-border-l4, #dcdcdc)',
        background: 'var(--dsw-alias-bg-layer-2, #f7f7f7)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        color: '#8a8a8a',
        fontSize: '10px',
        boxShadow: '0 2px 8px rgba(0,0,0,0.10)',
      },
      dot: {
        display: 'inline-block',
        width: '6px',
        height: '6px',
        borderRadius: '50%',
        background: '#ff8000',
        marginRight: '4px',
        verticalAlign: 'middle',
      },
    }

    /** 轮询 /status，只在有活跃目标时渲染小窗。 */
    // 会话服务在 apply 时赋值。slot 的 renderSlot 只传空 props，
    // 用模块级引用拿会话，保持注册形状是裸组件（包装成箭头函数会让 slot 不渲染）。
    let sessionsRef = null
    let warnedNoSession = false

    function LivePreview() {
      const [status, setStatus] = React.useState(null)
      // 记住"要看的那个窗口号"，不是下标。
      // 服务端按最近操作时间排序，顺序随时会变；用下标的话，
      // 你刚点开第 2 个，1.5 秒后排序一变，画面就自己跳到别人身上。
      const [selectedWindow, setSelectedWindow] = React.useState(0)
      // 当前会话：只有本会话发起的操作才在这里出预览。
      // cua-mcp 经 MCP _meta 带上会话标识，cua-live 按它归属目标窗口。
      // 会话标识只用于过滤，拿不到就退化成「显示全部」。
      // 任何一步都不能抛错：组件在 slot 的 crash 边界里，
      // 一旦抛出就被静默吞掉，右上角表现为彻底没有预览。
      const [sessionId, setSessionId] = React.useState('')
      React.useEffect(() => {
        const sessions = sessionsRef
        if (!sessions || !sessions.list || typeof sessions.list.getSnapshot !== 'function') {
          return undefined
        }
        const read = () => {
          try {
            setSessionId(sessions.list.getSnapshot()?.current ?? '')
          } catch {
            setSessionId('')
          }
        }
        read()
        try {
          const stop = sessions.list.subscribe(read)
          return () => {
            try { stop?.() } catch { /* 忽略 */ }
          }
        } catch {
          return undefined
        }
      }, [])

      React.useEffect(() => {
        let alive = true
        // 换会话先清空：新会话还没查完之前不要继续显示上一个会话的画面
        setStatus(null)
        // 没有会话标识就连查都不查。服务端在没有 session 时不过滤，
        // 会把所有会话的目标一起返回——请求都不发，才不会拿到别人的画面。
        if (!sessionId) {
          if (!warnedNoSession) {
            warnedNoSession = true
            console.warn('[dsh-cua] 拿不到当前会话标识，预览已停用')
          }
          return undefined
        }
        const poll = async () => {
          try {
            const query = sessionId ? '?session=' + encodeURIComponent(sessionId) : ''
            const res = await fetch(LIVE_BASE + '/status' + query, { cache: 'no-store' })
            const data = await res.json()
            if (alive) setStatus(data && data.active ? data : null)
          } catch {
            if (alive) setStatus(null)
          }
        }
        void poll()
        const timer = setInterval(poll, 1500)
        return () => {
          alive = false
          clearInterval(timer)
        }
      }, [sessionId])

      if (!status) return null
      // 拿不到会话标识就什么都不显示。服务端在没带 session 时不过滤，
      // 会把所有会话（包括别的脚本）的目标一起返回——那正好是要避免的串扰。
      // 这里空着，好过把别人的窗口画到你界面上。
      if (!sessionId) return null

      // 多目标按 Codex 的做法叠放：只显示一个主窗，其余错位露出一角，
      // 点序号切换要看哪个。不并排——并排会把标题栏撑得很宽很乱。
      // 还没抓到第一帧的目标也要留着：从发起到出帧有延迟，
      // 把它滤掉会让整个预览凭空消失一段时间。
      const targets = (Array.isArray(status.targets) ? status.targets : []).slice(0, 5)
      if (targets.length === 0) return null

      // 选中的窗口没了（被关掉或过期）就退回列表第一个
      let index = targets.findIndex((t) => t.window === selectedWindow)
      if (index < 0) index = 0
      const active = targets[index]

      const boxW = CARD_W

      const frameFor = (t) => {
        const fw = t.width > 0 ? t.width : 0
        const fh = t.height > 0 ? t.height : 0
        const ratio = fw > 0 && fh > 0 ? fh / fw : 0.62
        const boxH = Math.max(48, Math.min(88, Math.round(boxW * ratio)))
        return { width: boxW + 'px', height: boxH + 'px' }
      }

      const focusTarget = (t) => {
        fetch(LIVE_BASE + '/focus?window=' + t.window, { cache: 'no-store' }).catch(() => {})
      }

      const box = frameFor(active)
      // 后面的窗口只画边框，错位 3px 叠在主窗之下，露出边就够暗示"还有"
      const layered = targets.slice(index + 1).concat(targets.slice(0, index))

      return React.createElement(
        'div',
        { style: liveCss.stack },
        React.createElement(
          'div',
          { style: liveCss.deck },
          layered.slice(0, 2).reverse().map((t, i) => {
            const depth = layered.slice(0, 2).length - i
            return React.createElement('div', {
              key: 'back-' + t.window,
              style: Object.assign({}, liveCss.backCard, box, {
                transform: 'translate(' + depth * 3 + 'px, ' + depth * 3 + 'px)',
                zIndex: depth,
              }),
            })
          }),
          React.createElement(
            'div',
            {
              key: String(active.window),
              style: Object.assign({}, liveCss.wrap, { zIndex: 10 }),
              title: '点击跳到这个窗口',
              onClick: () => focusTarget(active),
              role: 'button',
              tabIndex: 0,
              onKeyDown: (e) => {
                if (e.key === 'Enter' || e.key === ' ') focusTarget(active)
              },
            },
            active.alive
              ? React.createElement('img', {
                  // 不能带 seq 做 cache buster：每次轮询 seq 都变，
                  // <img> 就会每秒重连一次 MJPEG，永远停在首帧之前。
                  src: LIVE_BASE + '/live.mjpg?win=' + active.window,
                  // contain 而不是 fill：高度有上限，4:3 的窗口按 fill 会把画面
                  // 纵向压掉一成多，看着像糊了。宁可左右留一点白。
                  style: Object.assign({}, liveCss.frame, box, { objectFit: 'contain' }),
                  alt: '实时操作画面',
                })
              : React.createElement(
                  'div',
                  { style: Object.assign({}, liveCss.checker, box) },
                  '连接中',
                ),
            React.createElement(
              'span',
              { style: liveCss.tag },
              React.createElement('span', { style: liveCss.dot }),
              active.app || '未知应用',
            ),
            targets.length > 1
              ? React.createElement(
                  'span',
                  {
                    style: liveCss.switcher,
                    title: '切换到下一个窗口',
                    role: 'button',
                    tabIndex: 0,
                    onKeyDown: (e) => {
                      if (e.key !== 'Enter' && e.key !== ' ') return
                      e.preventDefault()
                      e.stopPropagation()
                      const next = targets[(index + 1) % targets.length]
                      if (next) setSelectedWindow(next.window)
                    },
                    onClick: (e) => {
                      // 别把点击透给父级，否则会触发跳转
                      e.stopPropagation()
                      const next = targets[(index + 1) % targets.length]
                      if (next) setSelectedWindow(next.window)
                    },
                  },
                  index + 1 + '/' + targets.length,
                )
              : null,
          ),
        ),
      )
    }

    // ---- 样式：沿用宿主的 alias 变量，缺省时退回中性色 ----

    const css = {
      card: {
        border: '0.5px solid var(--dsw-alias-border-l4, #e3e3e3)',
        borderRadius: '12px',
        background: 'var(--dsw-alias-bg-layer-2, #ffffff)',
        marginBottom: '12px',
        overflow: 'hidden',
      },
      summary: {
        display: 'flex',
        alignItems: 'center',
        gap: '8px',
        padding: '14px 16px',
        cursor: 'pointer',
        listStyle: 'none',
      },
      title: {
        color: 'var(--dsw-alias-label-primary, #1a1a1a)',
        fontSize: '14px',
        fontWeight: '600',
      },
      desc: {
        color: 'var(--dsw-alias-label-tertiary, #8a8a8a)',
        fontSize: '12px',
        marginTop: '2px',
      },
      body: {
        borderTop: '0.5px solid var(--dsw-alias-border-l2, #ececec)',
        padding: '4px 16px 16px',
      },
      row: {
        display: 'flex',
        flexDirection: 'column',
        gap: '6px',
        padding: '12px 0',
      },
      rowHead: {
        display: 'flex',
        alignItems: 'center',
        gap: '8px',
      },
      label: {
        flex: '1',
        color: 'var(--dsw-alias-label-primary, #1a1a1a)',
        fontSize: '13px',
        fontWeight: '500',
      },
      hint: {
        color: 'var(--dsw-alias-label-tertiary, #8a8a8a)',
        fontSize: '12px',
        lineHeight: '1.5',
        margin: 0,
      },
      input: {
        border: '0.5px solid var(--dsw-alias-border-l4, #dcdcdc)',
        background: 'var(--dsw-alias-bg-layer-3, #fbfbfb)',
        color: 'var(--dsw-alias-label-primary, #1a1a1a)',
        borderRadius: '8px',
        height: '32px',
        padding: '0 10px',
        fontSize: '13px',
        font: 'inherit',
      },
      badge: {
        color: 'var(--dsw-alias-label-tertiary, #8a8a8a)',
        fontSize: '12px',
      },
      reset: {
        border: 'none',
        background: 'transparent',
        color: 'var(--dsw-alias-label-secondary, #5a5a5a)',
        fontSize: '12px',
        cursor: 'pointer',
        padding: 0,
        font: 'inherit',
      },
      footer: {
        display: 'flex',
        alignItems: 'center',
        gap: '10px',
        paddingTop: '10px',
      },
      save: {
        border: 'none',
        borderRadius: '8px',
        background: 'var(--dsw-alias-brand-primary, #339cff)',
        color: '#ffffff',
        fontSize: '13px',
        fontWeight: '500',
        padding: '7px 14px',
        cursor: 'pointer',
        font: 'inherit',
      },
      saveBlocked: {
        opacity: '0.45',
        cursor: 'default',
      },
      error: {
        color: 'var(--dsw-alias-label-error, #d93f3f)',
        fontSize: '12px',
      },
    }

    function renderField(spec, state, shell, props, disabled) {
      const id = `dsh-cua-field-${spec.field}`
      const value = state.value
      const blocked = disabled || !shell.available

      let control
      if (spec.kind === 'boolean') {
        control = h('input', {
          id,
          type: 'checkbox',
          checked: value === true,
          disabled: blocked,
          onChange: (event) => props.edit(spec.field, event.target.checked),
        })
      } else {
        control = h('input', {
          id,
          type: spec.kind === 'number' ? 'number' : 'text',
          value: value ?? '',
          disabled: blocked,
          style: css.input,
          onChange: (event) => props.edit(spec.field, event.target.value),
        })
      }

      const head = h(
        'div',
        { style: css.rowHead },
        spec.kind === 'boolean'
          ? h('label', { htmlFor: id, style: css.label, children: spec.label })
          : h('label', { htmlFor: id, style: css.label, children: spec.label }),
        state.overridden ? h('span', { style: css.badge, children: '已覆盖' }) : null,
        state.overridden
          ? h('button', {
              type: 'button',
              style: css.reset,
              disabled: blocked,
              onClick: () => props.resetField(spec.field),
              children: '重置',
            })
          : null,
      )

      return h(
        'div',
        { key: spec.field, style: css.row },
        head,
        spec.kind === 'boolean' ? h('div', { children: control }) : control,
        h('p', { style: css.hint, children: spec.hint }),
        state.invalid ? h('p', { style: css.error, children: '请输入有效数值' }) : null,
      )
    }

    /**
     * 配置卡片。hooks 由 slot 注入（`useCuaCard`），
     * 表单动作（edit / resetField / save / discard）直接展开在 props 上。
     */
    function CuaCard(props) {
      const state = props.useCuaCard((snapshot) => snapshot)
      const disabled = !state.writable
      const blocked = !state.dirty || state.saving || state.invalid || !state.available

      const footer = [
        h('button', {
          key: 'save',
          type: 'button',
          style: blocked ? { ...css.save, ...css.saveBlocked } : css.save,
          disabled: blocked,
          onClick: () => props.save(),
          children: state.saving ? '保存中…' : '保存',
        }),
        state.dirty
          ? h('button', {
              key: 'discard',
              type: 'button',
              style: css.reset,
              disabled: state.saving,
              onClick: () => props.discard(),
              children: '放弃修改',
            })
          : null,
        state.failed ? h('span', { key: 'err', style: css.error, children: '保存失败' }) : null,
      ]

      return h(
        'li',
        { style: css.card },
        h(
          'details',
          {},
          h(
            'summary',
            { style: css.summary },
            h('div', {
              children: [
                h('div', { key: 't', style: css.title, children: 'Computer Use（dsh-cua）' }),
                h('div', {
                  key: 'd',
                  style: css.desc,
                  children: '桌面操作、浏览器后台标签页、屏幕标记。改动即时生效，无需重启。',
                }),
              ],
            }),
          ),
          h(
            'div',
            { style: css.body },
            FIELDS.map((spec) =>
              renderField(
                spec,
                props.useCuaCard((snapshot) => snapshot[spec.field]),
                state,
                props,
                disabled,
              ),
            ),
            h('div', { style: css.footer }, footer),
          ),
        ),
      )
    }

    /** 需要的宿主服务：slot 注册表与 settings 作用域。 */
    // 不把 sessions 列进 inject：客户端没有这个服务名的话，
    // 插件会一直等它，apply 永远不执行，连配置卡片都不会渲染。
    // 会话标识只是过滤用的增强，改成运行时按需取，取不到就显示全部。
    const inject = ['slots', 'settingsScope']

    /**
     * 挂载配置卡片。
     * @param ctx - 浏览器侧插件上下文。
     */
    function apply(ctx) {
      const form = new CardForm(ctx.settingsScope.bind({ namespace: NS }), FIELDS)
      form.store = form.bind(() => ({
        ...form.shell(),
        ...Object.fromEntries(FIELDS.map((spec) => [spec.field, form.field(spec.field)])),
      }))
      ctx.effect(() => () => form.dispose(), 'dsh-cua: 配置卡片')
      ctx.slots.inject('settings.plugin.item', function* () {
        yield ctx.slots.register(
          {
            name: 'settings.plugin.item',
            key: NS,
            inject: () => form.inject(),
          },
          CuaCard,
        )
      })
      // 对话页右上角的实时画面。没有活跃目标时组件自己渲染 null，
      // 不占位、不显示空框。
      try {
        sessionsRef = ctx.sessions ?? ctx.get?.('sessions') ?? null
      } catch {
        sessionsRef = null
      }
      ctx.slots.inject('conversation.session.header.corner', function* () {
        yield ctx.slots.register(
          { name: 'conversation.session.header.corner' },
          LivePreview,
        )
      })
    }

    exports.name = 'cua'
    exports.apply = apply
    exports.inject = inject
    return module.exports
  },
})
