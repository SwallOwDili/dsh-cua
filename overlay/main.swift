// cua-overlay — 在被操作的 App 窗口上显示「AI 正在操作」标记
//
// 独立 NSApplication 进程，通过 Unix socket 接收指令：
//   {"cmd":"show","pid":123,"windowID":456,"label":"AI 正在操作"}
//   {"cmd":"hide"}
//
// 窗口特性：
//   - borderless + 透明背景 + 忽略鼠标事件（不阻挡用户操作）
//   - level = .normal，与虚拟光标同层，靠 order(above:) 贴在目标窗口上
//   - canJoinAllSpaces + fullScreenAuxiliary，全屏与切换 Space 时跟随
//   - 每 0.25s 轮询目标窗口 bounds，窗口移动/缩放时同步
//
// 视觉与 Codex 的 accentColor 一致（#339CFF）。

import Cocoa
import CoreGraphics


// MARK: - 虚拟光标

/// AI 操作位置的可见光标。click/type_text 走 postToPid，真实光标不动；
/// scroll/drag 走 HID tap，真实光标会动。两种情况都用这层虚拟光标
/// 给用户一个稳定的「AI 手指」视觉锚点。
final class CursorWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // 与「AI 正在操作」胶囊同层。用 .statusBar 会盖在所有普通窗口之上，
        // 目标被别的窗口遮住时光标还浮着，视觉上就"飘在天上"。
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CursorView: NSView {
    var clickPulseStart: Date?
    /// 移动光环起点。Codex 那边是 CursorSequence/LensSequence 的 PNG 帧序列，
    /// 这里用现画的光环等效：移动到新位置时从尖端扩散一圈，0.35s 淡出。
    var movePulseStart: Date?

    /// 指针形状：macOS 系统箭头的轮廓点（16 高缩放到 ~20pt）
    private let arrow: [NSPoint] = [
        NSPoint(x: 0, y: 0), NSPoint(x: 0, y: -25), NSPoint(x: 5.6, y: -19.4),
        NSPoint(x: 9.6, y: -28), NSPoint(x: 13, y: -26.4), NSPoint(x: 9.1, y: -17.8),
        NSPoint(x: 16.1, y: -17.7),
    ]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // 视图原点在左下；箭头以 (0,0) 为尖端，平移到视图左上区
        ctx.saveGState()
        ctx.translateBy(x: 8, y: bounds.height - 8)

        let path = NSBezierPath()
        path.move(to: arrow[0])
        for p in arrow.dropFirst() { path.line(to: p) }
        path.close()

        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 3
        sh.shadowOffset = NSSize(width: 0, height: 2)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
        sh.set()
        cursorFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        path.lineWidth = 2.0
        path.stroke()
        ctx.restoreGState()

        // 移动光环
        if let t0 = movePulseStart {
            let dt = Date().timeIntervalSince(t0)
            if dt < 0.35 {
                let k = CGFloat(dt / 0.35)
                let r = 6 + 22 * k
                let ring = NSBezierPath(ovalIn: NSRect(x: 0 - r, y: -r, width: r * 2, height: r * 2))
                ring.lineWidth = 2.0 * (1 - k * 0.6)
                cursorFill.withAlphaComponent(0.55 * (1 - k)).setStroke()
                ring.stroke()
                needsDisplay = true
            } else {
                movePulseStart = nil
            }
        }

        // 点击涟漪：从点击时刻起 0.45s 扩散淡出
        if let t0 = clickPulseStart {
            let dt = Date().timeIntervalSince(t0)
            if dt < 0.45 {
                let k = CGFloat(dt / 0.45)
                let cx = bounds.width / 2, cy = bounds.height / 2
                let ring = NSBezierPath(
                    ovalIn: NSRect(x: cx - 8 - 30 * k, y: cy - 8 - 30 * k,
                                   width: 16 + 60 * k, height: 16 + 60 * k))
                cursorFill.withAlphaComponent(0.85 * (1 - k)).setStroke()
                ring.lineWidth = 3
                ring.stroke()
            } else {
                clickPulseStart = nil
            }
        }
    }
}


/// 目标窗口是否仍在屏幕上（未关闭、未最小化）。
func windowOnScreen(_ id: CGWindowID) -> Bool {
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return false
    }
    for info in list where (info[kCGWindowNumber as String] as? UInt32) == id {
        return true
    }
    return false
}

final class CursorController {
    private let win = CursorWindow()
    private let view = CursorView()
    private var from: NSPoint = .zero
    private var to: NSPoint = .zero
    private var animStart: Date?
    private var timer: Timer?
    private var expiresAt: Date = .distantPast
    /// 目标窗口与所属进程：光标只在目标应用位于前台时显示，
    /// 跟胶囊标记同一套规则——不能比标记「更飘」。
    var targetPID: pid_t = 0
    var targetWindowID: CGWindowID = 0

    init() {
        win.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
    }

    /// 屏幕坐标(1x) → 窗口 frame（窗口左上对齐光标尖端）
    private func frame(at p: CGPoint) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: p.x, y: h - p.y - 64, width: 64, height: 64)
    }

    /// 把光标窗口排到目标窗口正上方。level 已降到 .normal，
    /// 所以别的窗口盖住目标时，光标跟着被盖住，不会浮在所有窗口之上。
    private func attachToTarget() {
        // 先上屏再排序：order(.above:) 不负责显示隐藏窗口
        win.orderFrontRegardless()
        guard targetWindowID != 0 else { return }
        win.order(.above, relativeTo: Int(targetWindowID))
    }

    /// 只要目标窗口还在屏上就显示光标。
    /// 不看前台：AI 操作后台窗口时，用户仍要能看到光标停在哪里。
    /// 目标被遮挡时，光标因为挂在目标窗口层级上，会跟着一起被遮挡。
    private func targetAllowsDisplay() -> Bool {
        guard targetPID != 0, targetWindowID != 0 else { return true }
        return windowOnScreen(CGWindowID(targetWindowID))
    }

    func move(to p: CGPoint, animated: Bool) {
        expiresAt = Date().addingTimeInterval(20)
        guard targetAllowsDisplay() else {
            hide()
            return
        }
        let target = frame(at: p)
        if !animated || !win.isVisible {
            from = NSPoint(x: target.minX, y: target.minY)
            win.setFrame(target, display: true)
            attachToTarget()
            animStart = nil
        } else {
            // TTL 隐藏后回到动画路径时必须重新上屏，否则动画在屏外跑
            if !win.isVisible { attachToTarget() }
            from = NSPoint(x: win.frame.minX, y: win.frame.minY)
            to = NSPoint(x: target.minX, y: target.minY)
            animStart = Date()
        }
        pulseAtCurrent()
        startTimer()
    }

    func pulseAtCurrent() {
        view.movePulseStart = Date()
        view.needsDisplay = true
    }

    func click(at p: CGPoint) {
        guard targetAllowsDisplay() else { return }
        move(to: p, animated: false)
        view.clickPulseStart = Date()
        expiresAt = Date().addingTimeInterval(20)
        startTimer()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        animStart = nil
        win.orderOut(nil)
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if Date() >= self.expiresAt { self.hide(); return }
            if !self.targetAllowsDisplay() { self.hide(); return }
            if let t0 = self.animStart {
                let k = min(1, Date().timeIntervalSince(t0) / 0.28)
                let e = 1 - pow(1 - CGFloat(k), 3)   // easeOutCubic
                let x = self.from.x + (self.to.x - self.from.x) * e
                let y = self.from.y + (self.to.y - self.from.y) * e
                self.win.setFrameOrigin(NSPoint(x: x, y: y))
                if k >= 1 { self.animStart = nil }
            }
            self.view.needsDisplay = true
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
}

let socketPath = "/tmp/cua-overlay.sock"

/// 版本标识。cua-mcp 启动时用 ping 校验，不匹配就杀掉旧进程重开，
/// 否则二进制更新后旧代码会一直在内存里跑。
enum Overlay {
    static let version = "5"
}
let accent = NSColor(srgbRed: 0x33 / 255.0, green: 0x9C / 255.0, blue: 0xFF / 255.0, alpha: 1.0)
/// 虚拟光标与左上角标记共用同一个强调色。
/// 早先用的是 #FF8000——那是从另一个项目（Infuse 逆向）串过来的品牌橙，
/// 在这里没有任何依据，和标记的蓝撞成两套视觉。统一到 accent。
let cursorFill = accent

// MARK: - 标记视图

final class BadgeView: NSView {
    var label: String = "AI 正在操作" {
        didSet { needsDisplay = true }
    }

    private let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private let hPad: CGFloat = 10
    private let vPad: CGFloat = 5
    private let dotSize: CGFloat = 7

    override var isFlipped: Bool { true }

    /// 标签整体尺寸（左上角胶囊）
    var badgeSize: NSSize {
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let w = hPad * 2 + dotSize + 6 + textSize.width
        let h = max(textSize.height + vPad * 2, 24)
        return NSSize(width: ceil(w), height: ceil(h))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let size = badgeSize

        // 左上角胶囊（锚定窗口左上，不画整窗边框）
        let badgeRect = NSRect(
            x: 10,
            y: 10,
            width: min(size.width, bounds.width - 20),
            height: size.height
        )
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: size.height / 2,
                                     yRadius: size.height / 2)

        // 轻微投影，保证在浅色窗口上也看得清
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        accent.setFill()
        badgePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // 呼吸圆点
        let dotRect = NSRect(
            x: badgeRect.minX + hPad,
            y: badgeRect.midY - dotSize / 2,
            width: dotSize, height: dotSize
        )
        NSColor.white.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // 文字
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let textSize = (label as NSString).size(withAttributes: textAttrs)
        let textOrigin = NSPoint(
            x: dotRect.maxX + 6,
            y: badgeRect.midY - textSize.height / 2
        )
        (label as NSString).draw(
            at: textOrigin,
            withAttributes: textAttrs
        )
    }
}

// MARK: - 覆盖窗口

final class OverlayWindow: NSWindow {
    /// 最后一次收到指令的时间，用于空闲自退
    nonisolated(unsafe) static var lastActivity = Date()
    static func noteActivity() { lastActivity = Date() }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 状态与窗口定位

final class OverlayController {
    private let window = OverlayWindow()
    private let view = BadgeView()
    private var targetWindowID: CGWindowID?
    private var targetPID: pid_t = 0
    private var timer: Timer?

    /// 自主超时：即使 cua-mcp 进程已经退出、没来得及发 hide，
    /// 标记也必须自己消失。定时器活在 overlay 进程里，不依赖调用方。
    private var expiresAt: Date = .distantPast

    /// 目标窗口被遮挡时自动隐藏，避免盖住用户正在用的窗口。
    private var hiddenByOcclusion = false

    init() {
        window.contentView = view
    }

    /// CGWindow bounds（左上原点，屏幕坐标）→ NSWindow frame（左下原点）
    private func nsFrame(fromCG rect: CGRect) -> NSRect {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        // 多屏时用包含该窗口中心点的屏幕高度
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var h = screenHeight
        for s in NSScreen.screens {
            let sf = s.frame
            if sf.contains(CGPoint(x: center.x, y: h - center.y)) {
                h = sf.height
                break
            }
        }
        return NSRect(
            x: rect.origin.x,
            y: h - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func currentBounds(of windowID: CGWindowID) -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            guard let num = info[kCGWindowNumber as String] as? CGWindowID, num == windowID else { continue }
            guard let b = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
            let x = b["X"] as? CGFloat ?? 0
            let y = b["Y"] as? CGFloat ?? 0
            let w = b["Width"] as? CGFloat ?? 0
            let h = b["Height"] as? CGFloat ?? 0
            if w < 2 || h < 2 { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    func show(windowID: CGWindowID, label: String, pid: pid_t, ttl: TimeInterval) {
        targetWindowID = windowID
        targetPID = pid
        view.label = label
        expiresAt = Date().addingTimeInterval(ttl)

        guard let rect = currentBounds(of: windowID) else {
            hide()
            return
        }
        layout(for: rect)
        // 先上屏，再贴到目标窗口正上方。
        // order(.above:) 只调整 z 序，对隐藏窗口不产生显示效果，
        // 所以两步都要做；只用 orderFrontRegardless 会让胶囊浮在所有窗口之上。
        window.orderFrontRegardless()
        window.order(.above, relativeTo: Int(windowID))
        hiddenByOcclusion = false

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    /// 把 overlay 窗口定位到目标窗口左上角，尺寸只占胶囊那么大。
    private func layout(for target: CGRect) {
        let frame = nsFrame(fromCG: target)
        let badge = view.badgeSize
        let pad: CGFloat = 12
        let w = min(badge.width + pad * 2, frame.width)
        let h = badge.height + pad * 2

        // NSWindow 坐标原点在左下，所以「左上角」是 y = maxY - h
        let overlayFrame = NSRect(
            x: frame.minX,
            y: frame.maxY - h,
            width: w,
            height: h
        )
        window.setFrame(overlayFrame, display: true)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        targetWindowID = nil
        targetPID = 0
        expiresAt = .distantPast
        hiddenByOcclusion = false
        window.orderOut(nil)
    }

    private func refresh() {
        guard let id = targetWindowID else { return }

        // 超时自毁
        if Date() >= expiresAt {
            hide()
            return
        }

        guard let rect = currentBounds(of: id) else {
            // 窗口已关闭或最小化
            hide()
            return
        }

        // 标记属于那个窗口，不属于屏幕。
        // 之前按「目标是否前台」决定显示/隐藏，结果是用户在浏览器里看 AI 操作
        // 后台应用时，标记整个消失，看不出 AI 在哪动手。
        // 正确做法是始终显示，并挂在目标窗口之上：
        // 目标被别的窗口盖住时，标记跟着被盖住，不会浮在最上层。
        layout(for: rect)
        if !window.isVisible || hiddenByOcclusion {
            hiddenByOcclusion = false
            window.orderFrontRegardless()
        }
        window.order(.above, relativeTo: Int(id))
    }
}

// MARK: - Socket 服务

final class CommandServer {
    private let controller = OverlayController()
    private let cursor = CursorController()
    private var listenFD: Int32 = -1

    func start() -> Bool {
        unlink(socketPath)

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count + 1) { dst in
                for (i, b) in pathBytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[pathBytes.count] = 0
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, len) }
        }
        guard bound == 0 else { return false }

        // 只允许当前用户访问
        chmod(socketPath, 0o600)

        guard listen(listenFD, 8) == 0 else { return false }

        Thread.detachNewThread { [weak self] in
            self?.acceptLoop()
        }
        return true
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            OverlayWindow.noteActivity()
            if fd < 0 { continue }

            // 一次 read 未必拿得到完整报文：短读时 JSON 解析失败，
            // 整条命令就被丢掉了（丢的可能是 cursor 移动，也可能是 quit）。
            // 给 socket 一个很短的接收超时，累积到能解析为止；
            // 超时说明对端没发完或发的不是 JSON，按坏命令丢弃。
            var tv = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

            var data = Data()
            var obj: [String: Any]?
            while data.count < 1 << 16 {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = read(fd, &chunk, chunk.count)
                if n > 0 {
                    data.append(contentsOf: chunk[0..<n])
                    if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        obj = parsed
                        break
                    }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                break
            }
            guard let obj, let cmd = obj["cmd"] as? String else { close(fd); continue }

            if cmd == "cursor" {
                let x = (obj["x"] as? Double) ?? 0
                let y = (obj["y"] as? Double) ?? 0
                let act = (obj["action"] as? String) ?? "move"
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    switch act {
                    case "click": self.cursor.click(at: CGPoint(x: x, y: y))
                    case "hide":  self.cursor.hide()
                    default:      self.cursor.move(to: CGPoint(x: x, y: y), animated: true)
                    }
                }
                close(fd)
                continue
            }

            // ping 在后台线程直接回包并关闭，不进主队列，避免阻塞 UI
            if cmd == "ping" {
                let body = try? JSONSerialization.data(withJSONObject: ["ok": true, "version": Overlay.version])
                if let body = body { _ = body.withUnsafeBytes { write(fd, $0.baseAddress, body.count) } }
                close(fd)
                continue
            }

            if cmd == "quit" {
                close(fd)
                DispatchQueue.main.async {
                    self.controller.hide()
                    exit(0)
                }
                continue
            }

            // 其余命令无回包，读完即关
            close(fd)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                switch cmd {
                case "show":
                    if let wid = obj["windowID"] as? Int {
                        let label = (obj["label"] as? String) ?? "AI 正在操作"
                        let pid = pid_t((obj["pid"] as? Int) ?? 0)
                        let ttl = (obj["ttl"] as? Double) ?? 20
                        // 光标与胶囊共用同一个目标：同层、同显示条件
                        self.cursor.targetPID = pid
                        self.cursor.targetWindowID = CGWindowID(wid)
                        self.controller.show(
                            windowID: CGWindowID(wid),
                            label: label,
                            pid: pid,
                            ttl: ttl
                        )
                    }
                case "hide":
                    self.controller.hide()
                    self.cursor.hide()
                default:
                    break
                }
            }
        }
    }
}

// MARK: - 入口

/// 空闲自退：浮层是被 mark 命令按需拉起的常驻进程，
/// 没人再发指令就该退出。否则它会一直悬在某个窗口上面，
/// 用户点那个应用时点击被浮层吃掉，表现为「应用打不开」。
let idleTimeout: TimeInterval = 60
DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
        if Date().timeIntervalSince(OverlayWindow.lastActivity) > idleTimeout {
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let server = CommandServer()
if !server.start() {
    FileHandle.standardError.write("cua-overlay: socket 启动失败 \(socketPath)\n".data(using: .utf8)!)
    exit(1)
}

app.run()
