// cua-overlay — 在被操作的 App 窗口上显示「AI 正在操作」标记
//
// 独立 NSApplication 进程，通过 Unix socket 接收指令：
//   {"cmd":"show","pid":123,"windowID":456,"label":"AI 正在操作"}
//   {"cmd":"hide"}
//
// 窗口特性：
//   - borderless + 透明背景 + 忽略鼠标事件（不阻挡用户操作）
//   - level = .statusBar，盖在目标窗口之上
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
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovable = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CursorView: NSView {
    var clickPulseStart: Date?

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
        cursorOrange.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.setStroke()
        path.lineWidth = 2.0
        path.stroke()
        ctx.restoreGState()

        // 点击涟漪：从点击时刻起 0.45s 扩散淡出
        if let t0 = clickPulseStart {
            let dt = Date().timeIntervalSince(t0)
            if dt < 0.45 {
                let k = CGFloat(dt / 0.45)
                let cx = bounds.width / 2, cy = bounds.height / 2
                let ring = NSBezierPath(
                    ovalIn: NSRect(x: cx - 8 - 30 * k, y: cy - 8 - 30 * k,
                                   width: 16 + 60 * k, height: 16 + 60 * k))
                cursorOrange.withAlphaComponent(0.85 * (1 - k)).setStroke()
                ring.lineWidth = 3
                ring.stroke()
            } else {
                clickPulseStart = nil
            }
        }
    }
}

final class CursorController {
    private let win = CursorWindow()
    private let view = CursorView()
    private var from: NSPoint = .zero
    private var to: NSPoint = .zero
    private var animStart: Date?
    private var timer: Timer?
    private var expiresAt: Date = .distantPast

    init() {
        win.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
    }

    /// 屏幕坐标(1x) → 窗口 frame（窗口左上对齐光标尖端）
    private func frame(at p: CGPoint) -> NSRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: p.x, y: h - p.y - 64, width: 64, height: 64)
    }

    func move(to p: CGPoint, animated: Bool) {
        expiresAt = Date().addingTimeInterval(20)
        let target = frame(at: p)
        if !animated || !win.isVisible {
            from = NSPoint(x: target.minX, y: target.minY)
            win.setFrame(target, display: true)
            win.orderFrontRegardless()
            animStart = nil
        } else {
            // TTL 隐藏后回到动画路径时必须重新上屏，否则动画在屏外跑
            if !win.isVisible { win.orderFrontRegardless() }
            from = NSPoint(x: win.frame.minX, y: win.frame.minY)
            to = NSPoint(x: target.minX, y: target.minY)
            animStart = Date()
        }
        startTimer()
    }

    func click(at p: CGPoint) {
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
/// 虚拟光标用品牌橙 #FF8000，尽可能在任何背景上突出，且与 Infuse/MiniPlayer 品牌色一致
let cursorOrange = NSColor(srgbRed: 1.0, green: 128.0 / 255.0, blue: 0.0, alpha: 1.0)

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
        level = .statusBar
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
        window.orderFrontRegardless()
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

        // 目标应用不再是前台时，不再把标记顶在最上层
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let targetIsFront = (frontmostPID == targetPID)

        if targetIsFront {
            if hiddenByOcclusion {
                hiddenByOcclusion = false
                layout(for: rect)
                window.orderFrontRegardless()
            } else {
                layout(for: rect)
            }
        } else {
            // 目标在后台：隐藏标记。窗口本身不可见，标记也不该浮在别人上面。
            if !hiddenByOcclusion {
                hiddenByOcclusion = true
                window.orderOut(nil)
            }
        }
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
            if fd < 0 { continue }

            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { close(fd); continue }

            let data = Data(buf[0..<n])
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = obj["cmd"] as? String else { close(fd); continue }

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
                        self.controller.show(
                            windowID: CGWindowID(wid),
                            label: label,
                            pid: pid,
                            ttl: ttl
                        )
                    }
                case "hide":
                    self.controller.hide()
                default:
                    break
                }
            }
        }
    }
}

// MARK: - 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let server = CommandServer()
if !server.start() {
    FileHandle.standardError.write("cua-overlay: socket 启动失败 \(socketPath)\n".data(using: .utf8)!)
    exit(1)
}

app.run()
