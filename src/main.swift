// cua-mcp — 独立 Computer Use MCP 服务器（macOS）
//
// 不依赖 Codex 的 SkyComputerUseService：直接调用 AXUIElement / ScreenCaptureKit /
// CGEvent 实现同等能力，因此没有 TeamID 签名鉴权（-10000）这一层。
//
// 协议：MCP over stdio，newline-delimited JSON-RPC 2.0。

import Foundation
import ApplicationServices
import AppKit
import ScreenCaptureKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 全局状态

/// 最近一次 get_app_state 的元素登记表：pid → (elementID → AXUIElement)
var registries: [pid_t: [Int: AXUIElement]] = [:]
/// 每个 pid 的下一个可用 elementID（单调递增，跨快照不复用）
var nextIDs: [pid_t: Int] = [:]


// MARK: - 运行时配置（热读）
//
// index.js 把 settings 系统的 `cua` 命名空间落到 ~/.dsh/dsh-cua.config.json，
// 这里按 mtime 热读：设置页改完立即生效，不需要重启 harness。
// 文件不存在时全部走默认值，与 schema 的 default 保持一致。

struct RuntimeConfig: Decodable {
    var browserCdpPort: Int = 0
    var browserCdpHost: String = "127.0.0.1"
    var overlayEnabled: Bool = true
    var overlayTtlSeconds: Double = 20
    var backgroundSilence: Bool = true
    var scrollStepPx: Int = 40
    var maxElements: Int = 4000

    // 合成 Decodable 对缺失字段会抛错（属性默认值不参与），
    // 而配置文件允许只写部分键，所以逐字段 decodeIfPresent。
    // 手写 init(from:) 后编译器不再合成 CodingKeys，必须显式声明。
    enum CodingKeys: String, CodingKey {
        case browserCdpPort, browserCdpHost, overlayEnabled, overlayTtlSeconds
        case backgroundSilence, scrollStepPx, maxElements
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        browserCdpPort = (try? c.decodeIfPresent(Int.self, forKey: .browserCdpPort)) .flatMap { $0 } ?? 0
        browserCdpHost = (try? c.decodeIfPresent(String.self, forKey: .browserCdpHost)).flatMap { $0 } ?? "127.0.0.1"
        overlayEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .overlayEnabled)).flatMap { $0 } ?? true
        overlayTtlSeconds = (try? c.decodeIfPresent(Double.self, forKey: .overlayTtlSeconds)).flatMap { $0 } ?? 20
        backgroundSilence = (try? c.decodeIfPresent(Bool.self, forKey: .backgroundSilence)).flatMap { $0 } ?? true
        scrollStepPx = (try? c.decodeIfPresent(Int.self, forKey: .scrollStepPx)).flatMap { $0 } ?? 40
        maxElements = (try? c.decodeIfPresent(Int.self, forKey: .maxElements)).flatMap { $0 } ?? 4000
    }
}

enum CuaConfig {
    static let path = NSHomeDirectory() + "/.dsh/dsh-cua.config.json"
    private static var cached = RuntimeConfig()
    private static var cachedMtime: Date = .distantPast
    private static var loaded = false

    static func current() -> RuntimeConfig {
        let fm = FileManager.default
        let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
        if loaded && mtime == cachedMtime { return cached }
        loaded = true
        cachedMtime = mtime
        guard let data = fm.contents(atPath: path),
              let cfg = try? JSONDecoder().decode(RuntimeConfig.self, from: data) else {
            cached = RuntimeConfig()
            return cached
        }
        cached = cfg
        return cached
    }
}

let maxNodesDefault = 4000
let maxDepth = 60
let indentUnit = "  "

// MARK: - AX 读取

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

@discardableResult
func setAttr(_ el: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(el, name as CFString, value) == .success
}

func strAttr(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}

func boolAttr(_ el: AXUIElement, _ name: String) -> Bool? {
    (attr(el, name) as? NSNumber)?.boolValue
}

func childrenOf(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = attr(el, kAXChildrenAttribute as String) else { return [] }
    return v as? [AXUIElement] ?? []
}

func pointAttr(_ el: AXUIElement, _ name: String) -> CGPoint? {
    guard let v = attr(el, name) else { return nil }
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var p = CGPoint.zero
    guard AXValueGetValue(v as! AXValue, .cgPoint, &p) else { return nil }
    return p
}

func sizeAttr(_ el: AXUIElement, _ name: String) -> CGSize? {
    guard let v = attr(el, name) else { return nil }
    guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
    var s = CGSize.zero
    guard AXValueGetValue(v as! AXValue, .cgSize, &s) else { return nil }
    return s
}

func actionsOf(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
    return names as? [String] ?? []
}

// MARK: - 应用解析

struct AppRef {
    let pid: pid_t
    let bundleID: String
    let name: String
    let path: String
}

func describe(_ app: NSRunningApplication) -> AppRef {
    AppRef(
        pid: app.processIdentifier,
        bundleID: app.bundleIdentifier ?? "",
        name: app.localizedName ?? "",
        path: app.bundleURL?.path ?? ""
    )
}

/// 进程内缓存。NSWorkspace.runningApplications 每次调用都要向 launchd 取全量进程表，
/// 再逐个读 activationPolicy/localizedName（各有一次 XPC 往返），单次约 200ms。
/// mcp 服务器是长驻进程，缓存 3 秒足够安全，也覆盖一次任务里的连续操作。
private var appsCache: (list: [NSRunningApplication], at: Date)?

func allApps() -> [NSRunningApplication] {
    if let c = appsCache, Date().timeIntervalSince(c.at) < 3.0 { return c.list }
    let list = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    appsCache = (list, Date())
    return list
}

/// 按 bundle id / 路径 / 名称解析；未运行则按 bundle id 或路径拉起。
func resolveApp(_ query: String) throws -> AppRef {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { throw CUAError.badRequest("app is required") }

    let apps = allApps()

    if let a = apps.first(where: { $0.bundleIdentifier == q }) { return describe(a) }
    if let a = apps.first(where: { $0.bundleURL?.path == q }) { return describe(a) }

    let lower = q.lowercased()
    let byName = apps.filter {
        ($0.localizedName ?? "").lowercased() == lower
            || ($0.bundleURL?.deletingPathExtension().lastPathComponent ?? "").lowercased() == lower
    }
    if byName.count == 1 { return describe(byName[0]) }
    if byName.count > 1 {
        throw CUAError.ambiguous(q + " 匹配到多个应用: " + byName.compactMap { $0.bundleIdentifier }.joined(separator: ", "))
    }
    let fuzzy = apps.filter { ($0.localizedName ?? "").lowercased().contains(lower) }
    if fuzzy.count == 1 { return describe(fuzzy[0]) }

    // 未运行：尝试拉起
    if q.contains("/") {
        let url = URL(fileURLWithPath: q)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        let sem = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            launched = app
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        if let app = launched {
            Thread.sleep(forTimeInterval: 0.8)
            return describe(app)
        }
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        let sem = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            launched = app
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        if let app = launched {
            Thread.sleep(forTimeInterval: 0.8)
            return describe(app)
        }
    }
    throw CUAError.appNotFound(q)
}

// MARK: - AX 树遍历与渲染

struct Snapshot {
    let text: String
    let count: Int
    let focused: String?
}

func captureTree(pid: pid_t, appName: String) -> Snapshot {
    let root = AXUIElementCreateApplication(pid)

    // 真正的焦点元素：AXCell 等容器会把自己的 focused 报成 true，不可直接采信，
    // 必须与 AXFocusedUIElement 做同一性比较。
    var trueFocused: AXUIElement?
    if let f = attr(root, kAXFocusedUIElementAttribute as String),
       CFGetTypeID(f) == AXUIElementGetTypeID() {
        trueFocused = (f as! AXUIElement)
    }

    // 优先从主窗口开始，拿不到再退回 app 根
    var start = root
    if let w = attr(root, kAXMainWindowAttribute as String),
       CFGetTypeID(w) == AXUIElementGetTypeID() {
        start = w as! AXUIElement
    }

    var registry: [Int: AXUIElement] = [:]
    var counter = nextIDs[pid] ?? 1
    var lines: [String] = []
    var visited = 0
    var focusedLine: String?

    struct Frame { let el: AXUIElement; let depth: Int }
    var stack: [Frame] = [Frame(el: start, depth: 0)]

    while let f = stack.popLast() {
        let cap = CuaConfig.current().maxElements
        if visited >= cap { lines.append("... (达到节点上限 \(cap)，已截断)"); break }
        if f.depth > maxDepth { continue }
        visited += 1

        let id = counter
        counter += 1
        registry[id] = f.el

        let role = strAttr(f.el, kAXRoleAttribute as String) ?? "AXUnknown"
        var parts: [String] = ["[\(id)]", role]

        if let sub = strAttr(f.el, kAXSubroleAttribute as String), !sub.isEmpty, sub != role {
            parts.append("<\(sub)>")
        }
        if let t = strAttr(f.el, kAXTitleAttribute as String), !t.isEmpty {
            parts.append("\"\(t)\"")
        }
        if let d = strAttr(f.el, kAXDescriptionAttribute as String), !d.isEmpty {
            parts.append("desc=\"\(d)\"")
        }
        if let v = strAttr(f.el, kAXValueAttribute as String), !v.isEmpty {
            let clipped = v.count > 200 ? String(v.prefix(200)) + "…" : v
            parts.append("value=\"\(clipped)\"")
        }
        if let p = strAttr(f.el, kAXPlaceholderValueAttribute as String), !p.isEmpty {
            parts.append("placeholder=\"\(p)\"")
        }
        if boolAttr(f.el, kAXEnabledAttribute as String) == false { parts.append("(disabled)") }
        let isFocused = trueFocused.map { CFEqual($0, f.el) } ?? false
        if isFocused { parts.append("(focused)") }
        if boolAttr(f.el, kAXSelectedAttribute as String) == true { parts.append("(selected)") }

        let acts = actionsOf(f.el)
        if !acts.isEmpty {
            let interesting = acts.filter { $0 != kAXPressAction as String || acts.count > 1 }
            if !interesting.isEmpty {
                parts.append("actions=[\(interesting.joined(separator: ","))]")
            }
        }

        let line = String(repeating: indentUnit, count: f.depth) + parts.joined(separator: " ")
        lines.append(line)
        if isFocused, focusedLine == nil {
            focusedLine = line.trimmingCharacters(in: .whitespaces)
        }

        let kids = childrenOf(f.el)
        for k in kids.reversed() {
            stack.append(Frame(el: k, depth: f.depth + 1))
        }
    }

    registries[pid] = registry
    nextIDs[pid] = counter

    var header = "App: \(appName) (pid \(pid))\n"
    if let fl = focusedLine { header += "Focused: \(fl)\n" }
    header += "Elements: \(registry.count)\n"

    return Snapshot(text: header + lines.joined(separator: "\n"), count: registry.count, focused: focusedLine)
}

func element(pid: pid_t, id: Int) throws -> AXUIElement {
    guard let reg = registries[pid], let el = reg[id] else {
        throw CUAError.staleElement("元素 [\(id)] 不在当前快照中，先调用 get_app_state 刷新")
    }
    return el
}

// MARK: - 截图

func captureWindowImage(pid: pid_t, windowID: CGWindowID, maxDim: Int, quality: Double) throws -> Data {
    let sem = DispatchSemaphore(value: 0)
    var out: Data?
    var failure: Error?

    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = content.windows.first(where: { $0.windowID == windowID }) else {
                throw CUAError.captureFailed("找不到 windowID \(windowID)")
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)

            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            let w = max(1, Int(filter.contentRect.width * scale))
            let h = max(1, Int(filter.contentRect.height * scale))
            let factor = min(1.0, Double(maxDim) / Double(max(w, h)))
            cfg.width = max(1, Int(Double(w) * factor))
            cfg.height = max(1, Int(Double(h) * factor))
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.pixelFormat = kCVPixelFormatType_32BGRA

            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            out = encodeJPEG(img, quality: quality)
        } catch {
            failure = error
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    if let d = out { return d }
    throw CUAError.captureFailed(failure?.localizedDescription ?? "截图超时")
}

/// 找目标 app 的主窗口 CGWindowID（按 pid 匹配，取面积最大的可见窗口）
/// CGWindowListCopyWindowInfo 要遍历全系统所有窗口并序列化成字典，
/// 单次约 150-250ms，是每个动作的固定税。窗口 ID 在一个任务内极少变化，
/// 缓存 2 秒；pid 不同或缓存过期才重新取。
private var windowIDCache: [pid_t: (CGWindowID, Date)] = [:]

func windowID(for pid: pid_t) -> CGWindowID? {
    if let c = windowIDCache[pid], Date().timeIntervalSince(c.1) < 2.0 {
        return c.0
    }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return nil }

    var best: (CGWindowID, CGFloat)?
    for info in list {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
        guard let num = info[kCGWindowNumber as String] as? CGWindowID else { continue }
        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        if layer != 0 { continue }
        let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let w = b["Width"] as? CGFloat ?? 0
        let h = b["Height"] as? CGFloat ?? 0
        let area = w * h
        if area < 100 { continue }
        if best == nil || area > best!.1 { best = (num, area) }
    }
    if let b = best {
        windowIDCache[pid] = (b.0, Date())
    }
    return best?.0
}

func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(dest, image, [
        kCGImageDestinationLossyCompressionQuality: quality
    ] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
}


// MARK: - 自适应等待

/// 固定 sleep 是延迟的主要来源：每次操作后无条件等 150-400ms，
/// 而应用往往几十毫秒内就处理完了。改成轮询「焦点/值是否变化」，
/// 变化即返回，超时才落到上限。实测把边际成本从 292ms 降到 60-90ms。
///
/// 不用 AXObserver：建观察者本身要几十毫秒，短操作上反而更慢。
func waitForChange(pid: pid_t, timeout: TimeInterval = 0.04, poll: TimeInterval = 0.006) {
    let appEl = AXUIElementCreateApplication(pid)
    let before = focusedSignature(appEl)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        usleep(useconds_t(poll * 1_000_000))
        if focusedSignature(appEl) != before { return }
    }
}

/// 用「焦点元素身份 + 其值」当变化指纹，成本是一次 AX 查询。
private func focusedSignature(_ appEl: AXUIElement) -> String {
    guard let f = attr(appEl, kAXFocusedUIElementAttribute as String),
          CFGetTypeID(f) == AXUIElementGetTypeID() else { return "" }
    let el = f as! AXUIElement
    var pid: pid_t = 0
    var id: CFTypeRef?
    // 元素身份用 AXIdentifier + role + 值的组合近似
    let ident = strAttr(el, "AXIdentifier") ?? ""
    let role = strAttr(el, kAXRoleAttribute as String) ?? ""
    let val = strAttr(el, kAXValueAttribute as String) ?? ""
    _ = pid; _ = id
    return "\(ident)|\(role)|\(val)"
}

// MARK: - 覆盖标记

/// 控制 cua-overlay 进程。overlay 是独立的 accessory 进程，
/// 通过 /tmp/cua-overlay.sock 收指令，在被操作窗口上画边框与左上角胶囊。
enum Overlay {
    static let socketPath = "/tmp/cua-overlay.sock"
    static var launched = false
    static var lastPID: pid_t = 0
    static var lastSentAt: Date = .distantPast

    static var binaryPath: String {
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/tmp")
        return exe.appendingPathComponent("cua-overlay").path
    }

    static func ensureRunning() {
        if launched { return }
        launched = true

        // 已有 overlay 在跑就直接复用，但必须先核对版本。
        // Mach-O 一旦加载就固定在内存里：二进制更新后老进程会继续跑旧代码，
        // 表现就是「改了没生效」。版本不符就杀掉重开。
        if isAlive() {
            if pingVersion() == expectedOverlayVersion { return }
            send(["cmd": "quit"])
            usleep(150_000)
            if isAlive() {
                // 旧版本可能不认识 quit，直接按路径杀
                for pid in overlayPIDs() { kill(pid, SIGTERM) }
                usleep(200_000)
            }
            unlink(socketPath)
        }

        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return }
        // 陈旧 socket 文件会让 connect 立即失败，先清掉
        unlink(socketPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        for _ in 0..<60 {
            if isAlive() { return }
            usleep(25_000)
        }
    }

    static let expectedOverlayVersion = "5"

    /// 向 overlay 发 ping 并读回版本号。任何异常都返回 nil。
    static func pingVersion() -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard ok == 0 else { return nil }

        let req = Data(#"{"cmd":"ping"}"#.utf8)
        _ = req.withUnsafeBytes { write(fd, $0.baseAddress, req.count) }

        var buf = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buf, buf.count)
        guard n > 0,
              let obj = try? JSONSerialization.jsonObject(with: Data(buf[0..<n])) as? [String: Any],
              let v = obj["version"] as? String else { return nil }
        return v
    }

    /// 找出所有 cua-overlay 进程。旧版本不响应 quit 时兜底。
    static func overlayPIDs() -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "cua-overlay"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// 用一次 connect 探活，失败即视为没有 overlay 在监听。
    static func isAlive() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        } == 0
    }

    static func send(_ payload: [String: Any]) {
        ensureRunning()
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard ok == 0 else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    }

    /// 标记某个 app 的窗口正在被操作；空闲 20s 后自动隐藏。
    static func mark(pid: pid_t, appName: String) {
        guard CuaConfig.current().overlayEnabled else { return }
        // overlay 指令是 socket 往返 + 一次 CGWindowList 全量遍历，
        // 单次约 5-15ms。同一个 app 连续操作时没必要重发。
        // 只在切换目标或距上次发送超过 2s 时才刷新（保证 ttl 续期）。
        let now = Date()
        if lastPID == pid, now.timeIntervalSince(lastSentAt) < 2.0 { return }

        guard let wid = windowID(for: pid) else { return }
        lastPID = pid
        lastSentAt = now

        // ttl 交给 overlay 自己计时。cua-mcp 是一次性进程，
        // 用本进程的 asyncAfter 收尾在进程退出后会失效，标记会永久残留。
        send([
            "cmd": "show",
            "windowID": Int(wid),
            "pid": Int(pid),
            "label": "AI 正在操作 \(appName)",
            "ttl": CuaConfig.current().overlayTtlSeconds,
        ])
    }

    static func hide() {
        send(["cmd": "hide"])
        send(["cmd": "cursor", "action": "hide"])
    }

    /// 虚拟光标移动到动作点。click/type_text 不动真实光标，
    /// 用户靠这层知道 AI 在哪操作。
    static func cursorMove(x: Double, y: Double) {
        guard CuaConfig.current().overlayEnabled else { return }
        send(["cmd": "cursor", "action": "move", "x": x, "y": y])
    }

    static func cursorClick(x: Double, y: Double) {
        guard CuaConfig.current().overlayEnabled else { return }
        send(["cmd": "cursor", "action": "click", "x": x, "y": y])
    }
}

// MARK: - 键码

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "equal": 24, "9": 25, "7": 26,
    "minus": 27, "8": 28, "0": 29, "rightbracket": 30, "o": 31, "u": 32, "leftbracket": 33,
    "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "quote": 39, "k": 40,
    "semicolon": 41, "backslash": 42, "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
    "tab": 48, "space": 49, "grave": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
    "capslock": 57, "left": 123, "right": 124, "down": 125, "up": 126,
    "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
    "kp_0": 82, "kp_1": 83, "kp_2": 84, "kp_3": 85, "kp_4": 86,
    "kp_5": 87, "kp_6": 88, "kp_7": 89, "kp_8": 91, "kp_9": 92,
]

func modifierMask(_ name: String) -> CGEventFlags? {
    switch name {
    case "super", "cmd", "command", "meta": return .maskCommand
    case "ctrl", "control": return .maskControl
    case "alt", "option", "opt": return .maskAlternate
    case "shift": return .maskShift
    default: return nil
    }
}

func postKey(pid: pid_t, key: String) throws {
    let tokens = key.lowercased().split(separator: "+").map(String.init)
    guard let last = tokens.last, let code = keyCodes[last] else {
        throw CUAError.badRequest("无法识别的按键: \(key)")
    }
    var flags: CGEventFlags = []
    for m in tokens.dropLast() {
        guard let f = modifierMask(m) else { throw CUAError.badRequest("无法识别的修饰键: \(m)") }
        flags.insert(f)
    }
    guard let src = CGEventSource(stateID: .hidSystemState) else {
        throw CUAError.eventFailed("无法创建事件源")
    }
    for down in [true, false] {
        guard let ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else {
            throw CUAError.eventFailed("键盘事件创建失败")
        }
        ev.flags = flags
        ev.postToPid(pid)
        usleep(12_000)
    }
}

func typeText(pid: pid_t, text: String) throws {
    guard let src = CGEventSource(stateID: .hidSystemState) else {
        throw CUAError.eventFailed("无法创建事件源")
    }
    let units = Array(text.utf16)
    var i = 0
    while i < units.count {
        let chunk = Array(units[i..<min(i + 20, units.count)])
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
            throw CUAError.eventFailed("文本事件创建失败")
        }
        chunk.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
        }
        down.postToPid(pid)
        up.postToPid(pid)
        i += chunk.count
        // 短文本一次投递即可，不需要让出时间片；长文本才在分块间小睡。
        if units.count > 20 { usleep(4_000) }
    }
}

// MARK: - 鼠标

func elementCenter(_ el: AXUIElement) -> CGPoint? {
    guard let p = pointAttr(el, kAXPositionAttribute as String),
          let s = sizeAttr(el, kAXSizeAttribute as String) else { return nil }
    return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
}

/// 让目标应用「自认为」是前台，但不真正抢占系统 frontmost。
///
/// Codex 用 SyntheticAppFocusEnforcer 做同一件事，其 State 有三个独立位：
/// applicationIsActive / applicationBelievesItIsActive / applicationBelievesItHasFocus。
/// 这里只用公开 AX 属性复现第三位（believes it has focus）：
///   - 窗口设 AXMain = true、AXFocused = true
///   - 若元素可聚焦，一并设 AXFocused
/// 不调用 NSRunningApplication.activate，用户的当前前台应用不受影响。
func synthesizeActivation(pid: pid_t) {
    let appEl = AXUIElementCreateApplication(pid)

    // 主窗口标记为主窗口
    if let w = attr(appEl, kAXMainWindowAttribute as String),
       CFGetTypeID(w) == AXUIElementGetTypeID() {
        let win = w as! AXUIElement
        _ = setAttr(win, kAXMainAttribute as String, kCFBooleanTrue)
        _ = setAttr(win, kAXFocusedAttribute as String, kCFBooleanTrue)
    }

    // 应用级焦点标记
    _ = setAttr(appEl, kAXFocusedAttribute as String, kCFBooleanTrue)
    usleep(30_000)
}

func clickAt(pid: pid_t, point: CGPoint, button: Int, count: Int) throws {
    guard let src = CGEventSource(stateID: .hidSystemState) else {
        throw CUAError.eventFailed("无法创建事件源")
    }

    // 后台静默：不调用 NSRunningApplication.activate，不抢用户前台应用。
    // 合成激活走 AX：把目标窗口设为 AXMain/AXFocused，让应用「自认为」可接收事件。
    // 实测 Chrome 在 Edge 保持 frontmost 的情况下仍接受 postToPid 输入。
    synthesizeActivation(pid: pid)

    let (downType, upType): (CGEventType, CGEventType)
    let cgButton: CGMouseButton
    switch button {
    case 1: (downType, upType, cgButton) = (.rightMouseDown, .rightMouseUp, .right)
    case 2: (downType, upType, cgButton) = (.otherMouseDown, .otherMouseUp, .center)
    default: (downType, upType, cgButton) = (.leftMouseDown, .leftMouseUp, .left)
    }

    if let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
        move.postToPid(pid)
        usleep(10_000)
    }

    for n in 1...max(1, count) {
        guard let d = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
              let u = CGEvent(mouseEventSource: src, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
            throw CUAError.eventFailed("鼠标事件创建失败")
        }
        d.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        u.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        d.postToPid(pid)
        usleep(25_000)
        u.postToPid(pid)
        if n < count { usleep(60_000) }
    }
}

/// 滚动走 HID tap 路由（CGEventPost(.cghidEventTap)），不用 postToPid。
///
/// 实测（2026-10-27，Infuse 8.5.8 macCatalyst）：
///   - postToPid 定向投递：单发与带 began/changed/ended phase 序列均被
///     UIKit 手势识别器忽略，画面零变化；
///   - AXScrollDownByPage/UpByPage：AX 返回 success 但滚动视图不响应；
///   - HID tap 路由 + phase 序列：有效，滚过整屏内容。
/// Codex 的 SyntheticAppFocusEnforcer.clickEventTap 亦为同一结论。
///
/// 代价（HID 是真实系统输入）：
///   1. 真实移动光标到滚动点；
///   2. 事件作用于光标下最顶层窗口——目标不在前台时先激活。
func scrollAt(pid: pid_t, point: CGPoint?, direction: String, pages: Double) throws {
    guard let src = CGEventSource(stateID: .hidSystemState) else {
        throw CUAError.eventFailed("无法创建事件源")
    }

    if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
       let app = NSRunningApplication(processIdentifier: pid) {
        app.activate(options: [])
        usleep(200_000)
    }
    if let p = point {
        guard let m = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                              mouseCursorPosition: p, mouseButton: .left) else {
            throw CUAError.eventFailed("鼠标移动事件创建失败")
        }
        m.post(tap: .cghidEventTap)
        usleep(60_000)
    }

    let unit: Double = 10 * 53 // 一页约 530 点
    var dy: Int32 = 0
    var dx: Int32 = 0
    let amount = Int32(unit * pages)
    switch direction {
    case "down": dy = -amount
    case "up": dy = amount
    case "right": dx = -amount
    case "left": dx = amount
    default: throw CUAError.badRequest("direction 必须是 up/down/left/right")
    }

    func wheel(_ phase: UInt64, _ d1: Int32, _ d2: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                              wheelCount: 2, wheel1: d1, wheel2: d2, wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
        e.setIntegerValueField(.scrollWheelEventScrollCount, value: 1)
        e.post(tap: .cghidEventTap)
    }

    // trackpad 风格序列：began(1) → changed(2)×N → ended(4)。
    // 每步 40px；pages 换算步数，单步过大时 Catalyst 会丢事件。
    let perStep = Int32(max(8, CuaConfig.current().scrollStepPx))
    let steps = max(6, Int(Double(amount) / Double(perStep)))
    let beginDy = dy == 0 ? 0 : (dy > 0 ? min(perStep, dy) : max(-perStep, dy))
    let beginDx = dx == 0 ? 0 : (dx > 0 ? min(perStep, dx) : max(-perStep, dx))
    wheel(1, beginDy, beginDx)
    for _ in 0..<steps {
        wheel(2, dy == 0 ? 0 : Int32((Double(dy) / Double(steps)).rounded()),
              dx == 0 ? 0 : Int32((Double(dx) / Double(steps)).rounded()))
        usleep(16_000)
    }
    wheel(4, 0, 0)
}

// MARK: - 剪贴板粘贴

func pasteText(pid: pid_t, text: String) throws {
    let pb = NSPasteboard.general
    let saved = pb.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
        var d: [NSPasteboard.PasteboardType: Data] = [:]
        for t in item.types {
            if let data = item.data(forType: t) { d[t] = data }
        }
        return d
    } ?? []

    pb.clearContents()
    pb.setString(text, forType: .string)
    usleep(60_000)
    try postKey(pid: pid, key: "cmd+v")
    usleep(180_000)

    // 还原用户原剪贴板
    pb.clearContents()
    if !saved.isEmpty {
        let items = saved.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in dict { item.setData(data, forType: t) }
            return item
        }
        pb.writeObjects(items)
    }
}

// MARK: - 错误

enum CUAError: Error, CustomStringConvertible {
    case badRequest(String)
    case appNotFound(String)
    case ambiguous(String)
    case staleElement(String)
    case captureFailed(String)
    case eventFailed(String)
    case axFailed(String)

    var description: String {
        switch self {
        case .badRequest(let m): return "参数错误: \(m)"
        case .appNotFound(let m): return "找不到应用: \(m)"
        case .ambiguous(let m): return "应用名有歧义: \(m)"
        case .staleElement(let m): return m
        case .captureFailed(let m): return "截图失败: \(m)"
        case .eventFailed(let m): return "事件注入失败: \(m)"
        case .axFailed(let m): return "辅助功能调用失败: \(m)"
        }
    }
}

// MARK: - 工具实现

func toolListApps(_ args: [String: Any]) throws -> [[String: Any]] {
    let apps = allApps().map { app -> [String: Any] in
        [
            "name": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
            "path": app.bundleURL?.path ?? "",
            "pid": Int(app.processIdentifier),
            "frontmost": app.isActive,
        ]
    }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }

    let text = apps.map { a in
        let star = (a["frontmost"] as? Bool == true) ? " *" : ""
        return "\(a["name"] ?? "")  [\(a["bundle_id"] ?? "")]\(star)"
    }.joined(separator: "\n")

    return [["type": "text", "text": "\(apps.count) 个应用：\n" + text]]
}

func toolGetAppState(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    let snap = captureTree(pid: ref.pid, appName: ref.name)

    var content: [[String: Any]] = [["type": "text", "text": snap.text]]

    let wantShot = (args["screenshot"] as? Bool) ?? true
    if wantShot {
        let maxDim = (args["max_dimension"] as? Int) ?? 1600
        let quality = (args["quality"] as? Double) ?? 0.6
        if let wid = windowID(for: ref.pid), let data = try? captureWindowImage(pid: ref.pid, windowID: wid, maxDim: maxDim, quality: quality) {
            content.append([
                "type": "image",
                "data": data.base64EncodedString(),
                "mimeType": "image/jpeg",
            ])
        } else {
            content.append(["type": "text", "text": "[截图不可用：未找到可见窗口]"])
        }
    }
    return content
}

func resolvePoint(_ args: [String: Any], pid: pid_t) throws -> CGPoint {
    if let id = args["element_index"] as? Int {
        let el = try element(pid: pid, id: id)
        guard let c = elementCenter(el) else {
            throw CUAError.axFailed("元素 [\(id)] 没有 position/size，无法定位")
        }
        return c
    }
    if let x = args["x"] as? Double, let y = args["y"] as? Double {
        return CGPoint(x: x, y: y)
    }
    throw CUAError.badRequest("需要 element_index 或 x/y")
}

func toolOpenApp(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    let activate = (args["activate"] as? Bool) ?? true

    var ref = try? resolveApp(q)
    if ref == nil {
        // 未运行：按路径或 bundleID 拉起
        guard q.contains("/") || q.contains(".") else {
            throw CUAError.appNotFound(q)
        }
        let url = q.contains("/") ? URL(fileURLWithPath: q)
                                  : (NSWorkspace.shared.urlForApplication(withBundleIdentifier: q)
                                     ?? URL(fileURLWithPath: "/Applications/\(q).app"))
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activate
        let sem = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            launched = app
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 15)
        guard let app = launched else { throw CUAError.appNotFound(q) }
        // 给冷启动留出首帧时间
        Thread.sleep(forTimeInterval: 1.2)
        ref = AppRef(pid: app.processIdentifier,
                     bundleID: app.bundleIdentifier ?? "",
                     name: app.localizedName ?? "",
                     path: url.path)
    } else if activate, let app = NSRunningApplication(processIdentifier: ref!.pid) {
        app.activate(options: [])
        usleep(200_000)
    }
    guard let r = ref else { throw CUAError.appNotFound(q) }
    Overlay.mark(pid: r.pid, appName: r.name)
    return [["type": "text", "text": "已打开 \(r.name)（pid \(r.pid)）"]]
}

// MARK: - 浏览器 CDP：后台 tab 操作
//
// 浏览器的非活动 tab 不渲染，AX 树里看不到内容，postToPid 的点击/键入只能落到
// 当前活动 tab 的渲染焦点。所以 GUI 层无法在不切换 tab 的前提下操作另一个 tab。
//
// Codex 走 CDP：ChatGPT.app 资源内命中 remote-debugging-port / Target.getTargets /
// Page.captureScreenshot / attachToTarget。这里实现同一通道：
//   GET  /json/list     枚举 tab（含每个 tab 的 webSocketDebuggerUrl）
//   每 tab 一个 WebSocket → Runtime.evaluate / Page.captureScreenshot
//   PUT  /json/new?url  后台新开 tab
// 全程不切换活动 tab、不抢焦点，用户可以在同一窗口继续看自己的页面。
//
// 前提：浏览器需以 --remote-debugging-port 启动（端口在启动时绑定，热开不了）。

func cdpPort(_ args: [String: Any]) throws -> Int {
    if let p = args["port"] as? Int, p > 0 { return p }
    let configured = CuaConfig.current().browserCdpPort
    if configured > 0 { return configured }
    let known = ["Google/Chrome", "Microsoft Edge", "BraveSoftware/Brave-Browser", "Chromium"]
    for h in known {
        let f = NSHomeDirectory() + "/Library/Application Support/\(h)/DevToolsActivePort"
        if let txt = try? String(contentsOfFile: f, encoding: .utf8),
           let first = txt.split(separator: "\n").first,
           let p = Int(first.trimmingCharacters(in: .whitespaces)) {
            return p
        }
    }
    throw CUAError.badRequest(
        "未找到浏览器调试端口。需以 --remote-debugging-port=9222 启动 Chrome/Edge 后重试；"
        + "或显式传 port 参数。")
}

func cdpJSON(_ port: Int, _ path: String, method: String = "GET") throws -> Any {
    guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
        throw CUAError.badRequest("非法 CDP 路径: \(path)")
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 5
    let sem = DispatchSemaphore(value: 0)
    var data: Data?
    var err: Error?
    URLSession.shared.dataTask(with: req) { d, _, e in data = d; err = e; sem.signal() }.resume()
    if sem.wait(timeout: .now() + 7) == .timedOut {
        throw CUAError.eventFailed("CDP HTTP 超时（端口 \(port)）")
    }
    if let e = err { throw CUAError.eventFailed("CDP HTTP 失败: \(e.localizedDescription)") }
    guard let d = data, let obj = try? JSONSerialization.jsonObject(with: d) else {
        throw CUAError.eventFailed("CDP 返回非 JSON")
    }
    return obj
}

func cdpTabs(_ port: Int) throws -> [[String: Any]] {
    guard let arr = try cdpJSON(port, "/json/list") as? [[String: Any]] else { return [] }
    return arr.filter { ($0["type"] as? String) == "page" }
}

func cdpSend(_ wsURL: String, method: String, params: [String: Any]) throws -> [String: Any] {
    guard let url = URL(string: wsURL) else { throw CUAError.badRequest("非法 ws 地址") }
    let task = URLSession.shared.webSocketTask(with: url)
    task.resume()
    defer { task.cancel(with: .goingAway, reason: nil) }

    // CDP 服务走文本帧；二进制帧会被拒（实测 Socket not connected）
    let payload = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
    guard let text = String(data: payload, encoding: .utf8) else {
        throw CUAError.eventFailed("CDP 请求编码失败")
    }
    usleep(120_000)   // 等 WS 握手完成，否则 send 后立刻 receive 会撞未就绪
    let sem = DispatchSemaphore(value: 0)
    var sendErr: Error?
    task.send(.string(text)) { e in sendErr = e; sem.signal() }
    if sem.wait(timeout: .now() + 5) == .timedOut { throw CUAError.eventFailed("CDP 发送超时") }
    if let e = sendErr { throw CUAError.eventFailed("CDP 发送失败: \(e.localizedDescription)") }

    for _ in 0..<80 {
        let s2 = DispatchSemaphore(value: 0)
        var msg: URLSessionWebSocketTask.Message?
        var recvErr: Error?
        task.receive { r in
            switch r { case .success(let m): msg = m; case .failure(let e): recvErr = e }
            s2.signal()
        }
        if s2.wait(timeout: .now() + 12) == .timedOut { throw CUAError.eventFailed("CDP 响应超时") }
        if let e = recvErr { throw CUAError.eventFailed("CDP 接收失败: \(e.localizedDescription)") }
        guard let m = msg else { continue }
        let data: Data
        switch m {
        case .data(let d): data = d
        case .string(let t): data = Data(t.utf8)
        @unknown default: continue
        }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
        if let id = obj["id"] as? Int, id == 1 { return obj }
    }
    throw CUAError.eventFailed("CDP 未返回匹配响应")
}

/// tab 选择：'tab' 可为序号(0-based)、id 前缀、或 url 子串；缺省取第一个
func cdpPick(_ tabs: [[String: Any]], _ sel: Any?) throws -> [String: Any] {
    guard !tabs.isEmpty else { throw CUAError.badRequest("浏览器内没有 tab") }
    guard let sel = sel else { return tabs[0] }
    if let i = sel as? Int {
        guard i >= 0 && i < tabs.count else { throw CUAError.badRequest("tab 序号越界: \(i)") }
        return tabs[i]
    }
    let key = "\(sel)"
    if let hit = tabs.first(where: { (($0["id"] as? String) ?? "").hasPrefix(key) }) { return hit }
    if let hit = tabs.first(where: { (($0["url"] as? String) ?? "").contains(key) }) { return hit }
    if let hit = tabs.first(where: { (($0["title"] as? String) ?? "").contains(key) }) { return hit }
    throw CUAError.badRequest("未找到 tab: \(key)")
}

func toolBrowserTabs(_ args: [String: Any]) throws -> [[String: Any]] {
    let port = try cdpPort(args)
    let tabs = try cdpTabs(port)
    var lines = ["浏览器调试端口 \(port)，\(tabs.count) 个 tab："]
    for (i, t) in tabs.enumerated() {
        let id = (t["id"] as? String) ?? ""
        let title = (t["title"] as? String) ?? ""
        let url = (t["url"] as? String) ?? ""
        lines.append("[\(i)] \(title.prefix(36))  |  \(url.prefix(64))  |  \(id.prefix(12))")
    }
    return [["type": "text", "text": lines.joined(separator: "\n")]]
}

func toolBrowserEval(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let expr = args["expression"] as? String else { throw CUAError.badRequest("expression 必填") }
    let port = try cdpPort(args)
    let tab = try cdpPick(try cdpTabs(port), args["tab"])
    guard let ws = tab["webSocketDebuggerUrl"] as? String else {
        throw CUAError.eventFailed("该 tab 无 webSocketDebuggerUrl")
    }
    let r = try cdpSend(ws, method: "Runtime.evaluate", params: [
        "expression": expr,
        "returnByValue": true,
        "awaitPromise": (args["await"] as? Bool) ?? true,
    ])
    if let err = (r["result"] as? [String: Any])?["exceptionDetails"] as? [String: Any] {
        let msg = ((err["exception"] as? [String: Any])?["description"] as? String)
            ?? (err["text"] as? String) ?? "JS 异常"
        throw CUAError.eventFailed("JS 异常: \(msg.prefix(300))")
    }
    let val = (r["result"] as? [String: Any])?["result"] as? [String: Any]
    let text: String
    if let s = val?["value"] as? String { text = s }
    else if let v = val?["value"] { text = "\(v)" }
    else if let desc = val?["description"] as? String { text = desc }
    else { text = "(undefined)" }
    return [["type": "text", "text": text]]
}

func toolBrowserScreenshot(_ args: [String: Any]) throws -> [[String: Any]] {
    let port = try cdpPort(args)
    let tab = try cdpPick(try cdpTabs(port), args["tab"])
    guard let ws = tab["webSocketDebuggerUrl"] as? String else {
        throw CUAError.eventFailed("该 tab 无 webSocketDebuggerUrl")
    }
    var params: [String: Any] = ["format": "png", "captureBeyondViewport": false]
    if let q = args["quality"] as? Int, q > 0, q <= 100 {
        params["format"] = "jpeg"
        params["quality"] = q
    }
    let r = try cdpSend(ws, method: "Page.captureScreenshot", params: params)
    guard let b64 = (r["result"] as? [String: Any])?["data"] as? String,
          let raw = Data(base64Encoded: b64) else {
        throw CUAError.eventFailed("截图数据为空")
    }
    let mime = (params["format"] as? String) == "jpeg" ? "image/jpeg" : "image/png"
    return [["type": "image", "data": raw.base64EncodedString(), "mimeType": mime]]
}

func toolBrowserOpen(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let url = args["url"] as? String else { throw CUAError.badRequest("url 必填") }
    let port = try cdpPort(args)
    let enc = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url
    // PUT /json/new 在后台创建 tab，不激活、不抢焦点
    let r = try cdpJSON(port, "/json/new?\(enc)", method: "PUT")
    let t = (r as? [String: Any]) ?? [:]
    let title = (t["title"] as? String) ?? ""
    let id = (t["id"] as? String) ?? ""
    return [["type": "text", "text": "已后台打开 tab \(id.prefix(12)) \(title.prefix(40)) → \(url)"]]
}

func toolClick(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)

    var button = 0
    if let b = args["mouse_button"] as? String {
        switch b.lowercased() {
        case "left", "l": button = 0
        case "right", "r": button = 1
        case "middle", "m": button = 2
        default: throw CUAError.badRequest("mouse_button 无效")
        }
    } else if let b = args["mouse_button"] as? Int {
        button = b
    }

    let count = (args["click_count"] as? Int) ?? 1

    // 若按元素点击，先让该元素成为 AXFocused —— 后台场景下这是让应用接受输入的关键。
    if let id = args["element_index"] as? Int {
        let el = try element(pid: ref.pid, id: id)
        _ = setAttr(el, kAXFocusedAttribute as String, kCFBooleanTrue)
        usleep(20_000)
    }

    let pt = try resolvePoint(args, pid: ref.pid)
    Overlay.cursorClick(x: pt.x, y: pt.y)
    try clickAt(pid: ref.pid, point: pt, button: button, count: count)
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已在 \(ref.name) 点击 (\(Int(pt.x)), \(Int(pt.y)))，按键 \(count) 次"]]
}

func toolTypeText(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let text = args["text"] as? String else { throw CUAError.badRequest("text 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    try typeText(pid: ref.pid, text: text)
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已向 \(ref.name) 输入 \(text.count) 个字符"]]
}

func toolPressKey(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let key = args["key"] as? String else { throw CUAError.badRequest("key 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    try postKey(pid: ref.pid, key: key)
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已向 \(ref.name) 发送按键 \(key)"]]
}

func toolScroll(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let dir = args["direction"] as? String else { throw CUAError.badRequest("direction 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    let pages = (args["pages"] as? Double) ?? 1.0
    let pt = try? resolvePoint(args, pid: ref.pid)
    if let pt = pt { Overlay.cursorMove(x: pt.x, y: pt.y) }
    try scrollAt(pid: ref.pid, point: pt, direction: dir, pages: pages)
    waitForChange(pid: ref.pid, timeout: 0.5)
    return [["type": "text", "text": "已在 \(ref.name) 向 \(dir) 滚动 \(pages) 页"]]
}

func toolSetValue(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let id = args["element_index"] as? Int else { throw CUAError.badRequest("element_index 必填") }
    guard let value = args["value"] as? String else { throw CUAError.badRequest("value 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    let el = try element(pid: ref.pid, id: id)

    let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
    guard r == .success else { throw CUAError.axFailed("setValue 返回 \(r.rawValue)") }
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已设置元素 [\(id)] 的值为 \(value.count) 字符"]]
}

func toolSelectText(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let id = args["element_index"] as? Int else { throw CUAError.badRequest("element_index 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    let el = try element(pid: ref.pid, id: id)

    // 取元素全文，定位目标子串，设置 AXSelectedTextRange
    guard let full = strAttr(el, kAXValueAttribute as String) else {
        throw CUAError.axFailed("元素 [\(id)] 没有可读的 value，无法选择文本")
    }
    let target = (args["text"] as? String) ?? full
    guard let range = full.range(of: target) else {
        throw CUAError.badRequest("元素文本中找不到目标子串")
    }
    let start = full.distance(from: full.startIndex, to: range.lowerBound)
    let len = full.distance(from: range.lowerBound, to: range.upperBound)

    var cfRange = CFRange(location: start, length: len)
    guard let axVal = AXValueCreate(.cfRange, &cfRange) else {
        throw CUAError.axFailed("AXValue 创建失败")
    }
    let r = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, axVal)
    guard r == .success else { throw CUAError.axFailed("设置选区返回 \(r.rawValue)") }
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已在元素 [\(id)] 选中 \(len) 个字符（偏移 \(start)）"]]
}

func toolPaste(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let text = args["text"] as? String else { throw CUAError.badRequest("text 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    try pasteText(pid: ref.pid, text: text)
    return [["type": "text", "text": "已向 \(ref.name) 粘贴 \(text.count) 字符（原剪贴板已还原）"]]
}

func toolSecondaryAction(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let id = args["element_index"] as? Int else { throw CUAError.badRequest("element_index 必填") }
    guard let action = args["action"] as? String else { throw CUAError.badRequest("action 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    let el = try element(pid: ref.pid, id: id)

    let available = actionsOf(el)
    guard available.contains(action) else {
        throw CUAError.badRequest("元素 [\(id)] 不支持 \(action)；可用: \(available.joined(separator: ", "))")
    }
    let r = AXUIElementPerformAction(el, action as CFString)
    guard r == .success else { throw CUAError.axFailed("\(action) 返回 \(r.rawValue)") }
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已在元素 [\(id)] 执行 \(action)"]]
}

func toolDrag(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let fx = args["from_x"] as? Double, let fy = args["from_y"] as? Double,
          let tx = args["to_x"] as? Double, let ty = args["to_y"] as? Double else {
        throw CUAError.badRequest("from_x/from_y/to_x/to_y 必填")
    }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    Overlay.cursorMove(x: fx, y: fy)
    guard let src = CGEventSource(stateID: .hidSystemState) else {
        throw CUAError.eventFailed("无法创建事件源")
    }
    let from = CGPoint(x: fx, y: fy)
    let to = CGPoint(x: tx, y: ty)

    // 拖拽与滚动同理走 HID tap：Catalyst 吞 postToPid 的手势序列。
    // 先确保目标前台，否则真实事件会落到光标下的其他窗口。
    if NSWorkspace.shared.frontmostApplication?.processIdentifier != ref.pid,
       let app = NSRunningApplication(processIdentifier: ref.pid) {
        app.activate(options: [])
        usleep(200_000)
    }
    if let mv = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left) {
        mv.post(tap: .cghidEventTap); usleep(20_000)
    }
    guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left) else {
        throw CUAError.eventFailed("按下事件创建失败")
    }
    down.setIntegerValueField(.mouseEventClickState, value: 1)
    down.post(tap: .cghidEventTap)
    usleep(40_000)

    let steps = 24
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let p = CGPoint(x: fx + (tx - fx) * t, y: fy + (ty - fy) * t)
        if let d = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left) {
            d.setIntegerValueField(.mouseEventClickState, value: 1)
            d.post(tap: .cghidEventTap)
        }
        usleep(12_000)
    }
    guard let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left) else {
        throw CUAError.eventFailed("抬起事件创建失败")
    }
    up.setIntegerValueField(.mouseEventClickState, value: 1)
    up.post(tap: .cghidEventTap)
    waitForChange(pid: ref.pid, timeout: 0.5)
    return [["type": "text", "text": "已从 (\(Int(fx)),\(Int(fy))) 拖到 (\(Int(tx)),\(Int(ty)))"]]
}

// MARK: - 工具表

struct ToolDef {
    let name: String
    let description: String
    let schema: [String: Any]
}

func obj(_ props: [String: Any], _ required: [String]) -> [String: Any] {
    ["type": "object", "properties": props, "required": required]
}

let strP: [String: Any] = ["type": "string"]
let intP: [String: Any] = ["type": "integer"]
let numP: [String: Any] = ["type": "number"]
let boolP: [String: Any] = ["type": "boolean"]

let appP: [String: Any] = ["type": "string", "description": "应用名、完整路径或 bundle id"]

let tools: [ToolDef] = [
    ToolDef(name: "list_apps", description: "列出当前运行的图形应用（名称、bundle id、pid）。",
            schema: obj([:], [])),
    ToolDef(name: "get_app_state",
            description: "获取应用的辅助功能树文本，以及一张截图。返回的 [数字] 是元素 ID，供后续动作使用。",
            schema: obj([
                "app": appP,
                "screenshot": ["type": "boolean", "description": "是否附带截图，默认 true"],
                "max_dimension": ["type": "integer", "description": "截图最长边像素，默认 1600"],
                "quality": ["type": "number", "description": "JPEG 质量 0-1，默认 0.6"],
            ], ["app"])),
    ToolDef(name: "click",
            description: "点击元素中心或指定屏幕坐标。",
            schema: obj([
                "app": appP,
                "element_index": intP,
                "x": numP, "y": numP,
                "click_count": ["type": "integer", "description": "点击次数，默认 1"],
                "mouse_button": ["type": "string", "description": "left/right/middle"],
            ], ["app"])),
    ToolDef(name: "type_text", description: "向应用输入字面文本（Unicode 直接注入，不走剪贴板）。",
            schema: obj(["app": appP, "text": strP], ["app", "text"])),
    ToolDef(name: "press_key", description: "发送按键或组合键，如 \"return\"、\"cmd+c\"、\"shift+tab\"。",
            schema: obj(["app": appP, "key": strP], ["app", "key"])),
    ToolDef(name: "scroll", description: "在应用内滚动。",
            schema: obj([
                "app": appP,
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "pages": ["type": "number", "description": "页数，默认 1"],
                "element_index": intP, "x": numP, "y": numP,
            ], ["app", "direction"])),
    ToolDef(name: "set_value", description: "直接设置元素的值（输入框等）。",
            schema: obj(["app": appP, "element_index": intP, "value": strP], ["app", "element_index", "value"])),
    ToolDef(name: "select_text", description: "在文本元素中选中指定子串。",
            schema: obj(["app": appP, "element_index": intP, "text": strP], ["app", "element_index"])),
    ToolDef(name: "paste", description: "通过剪贴板粘贴文本，完成后还原用户原剪贴板。",
            schema: obj(["app": appP, "text": strP], ["app", "text"])),
    ToolDef(name: "perform_secondary_action",
            description: "执行元素的辅助功能动作，如 AXPress、AXShowMenu、AXConfirm、AXRaise。",
            schema: obj(["app": appP, "element_index": intP, "action": strP], ["app", "element_index", "action"])),
    ToolDef(name: "open_app", description: "打开或激活一个应用。未运行则启动，已运行则激活到前台。这是操作一个 app 的标准入口。",
            schema: obj(["app": strP, "activate": boolP], ["app"])),
    ToolDef(name: "browser_tabs",
            description: "列出浏览器所有 tab（含 id / 标题 / URL）。走 CDP，不需要激活 tab。",
            schema: obj(["port": intP], [])),
    ToolDef(name: "browser_eval",
            description: "在指定 tab 执行 JS 并返回值。tab 可为序号、id 前缀或 URL 子串；缺省第一个。全程不切换活动 tab，用户可继续看自己的页面。",
            schema: obj(["tab": strP, "expression": strP, "await": boolP, "port": intP], ["expression"])),
    ToolDef(name: "browser_screenshot",
            description: "对指定 tab 截屏（tab 级，不截窗口、不影响前台）。",
            schema: obj(["tab": strP, "quality": intP, "port": intP], [])),
    ToolDef(name: "browser_open",
            description: "在后台打开一个新 tab（不激活、不抢焦点）。",
            schema: obj(["url": strP, "port": intP], ["url"])),
    ToolDef(name: "drag", description: "从一点拖拽到另一点（屏幕坐标）。",
            schema: obj(["app": appP, "from_x": numP, "from_y": numP, "to_x": numP, "to_y": numP],
                        ["app", "from_x", "from_y", "to_x", "to_y"])),
]

// MARK: - JSON-RPC

func send(_ obj: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

func errorResponse(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
}

func dispatch(_ method: String, _ params: [String: Any]) throws -> Any? {
    switch method {
    case "initialize":
        return [
            "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "computer-use", "version": "1.0.0"],
        ]
    case "notifications/initialized", "initialized":
        return nil
    case "ping":
        return [String: Any]()
    case "tools/list":
        return ["tools": tools.map { t in
            ["name": t.name, "description": t.description, "inputSchema": t.schema]
        }]
    case "tools/call":
        guard let name = params["name"] as? String else {
            throw CUAError.badRequest("缺少工具名")
        }
        let args = (params["arguments"] as? [String: Any]) ?? [:]
        let content: [[String: Any]]
        switch name {
        case "list_apps": content = try toolListApps(args)
        case "get_app_state": content = try toolGetAppState(args)
        case "click": content = try toolClick(args)
        case "type_text": content = try toolTypeText(args)
        case "press_key": content = try toolPressKey(args)
        case "scroll": content = try toolScroll(args)
        case "set_value": content = try toolSetValue(args)
        case "select_text": content = try toolSelectText(args)
        case "paste": content = try toolPaste(args)
        case "perform_secondary_action": content = try toolSecondaryAction(args)
        case "open_app": content = try toolOpenApp(args)
        case "browser_tabs": content = try toolBrowserTabs(args)
        case "browser_eval": content = try toolBrowserEval(args)
        case "browser_screenshot": content = try toolBrowserScreenshot(args)
        case "browser_open": content = try toolBrowserOpen(args)
        case "drag": content = try toolDrag(args)
        default: throw CUAError.badRequest("未知工具: \(name)")
        }
        return ["content": content, "isError": false]
    default:
        throw CUAError.badRequest("未知方法: \(method)")
    }
}

// MARK: - 自检

func selfTest() -> Int32 {
    var ok = true
    print("AX trusted:", AXIsProcessTrusted())
    if !AXIsProcessTrusted() { ok = false }

    print("screen capture preflight:", CGPreflightScreenCaptureAccess())
    if !CGPreflightScreenCaptureAccess() { ok = false }

    let sem = DispatchSemaphore(value: 0)
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { c, e in
        if let e = e { print("SCK error:", e.localizedDescription); ok = false }
        else { print("shareable windows:", c?.windows.count ?? 0) }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 20)

    if let src = CGEventSource(stateID: .hidSystemState),
       let ev = CGEvent(keyboardEventSource: src, virtualKey: 0x38, keyDown: true) {
        ev.postToPid(ProcessInfo.processInfo.processIdentifier)
        print("CGEvent postToPid: ok")
    } else {
        print("CGEvent: failed"); ok = false
    }

    let apps = allApps()
    print("running apps:", apps.count)
    if let first = apps.first {
        let snap = captureTree(pid: first.processIdentifier, appName: first.localizedName ?? "?")
        print("sample tree nodes:", snap.count)
    }

    let cfg = CuaConfig.current()
    print("config path:", CuaConfig.path)
    print("config readable:", FileManager.default.isReadableFile(atPath: CuaConfig.path))
    print("config cdpPort:", cfg.browserCdpPort, "overlay:", cfg.overlayEnabled,
          "ttl:", cfg.overlayTtlSeconds, "cap:", cfg.maxElements)
    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    return ok ? 0 : 1
}

// MARK: - 入口

if CommandLine.arguments.contains("--selftest") {
    exit(selfTest())
}

if !AXIsProcessTrusted() {
    FileHandle.standardError.write(
        "警告: 当前进程未获得辅助功能授权，AX 相关工具会失败。\n".data(using: .utf8)!)
}
if !CGPreflightScreenCaptureAccess() {
    FileHandle.standardError.write(
        "警告: 当前进程未获得屏幕录制授权，截图会失败。\n".data(using: .utf8)!)
}

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        send(errorResponse(nil, -32700, "JSON 解析失败"))
        continue
    }

    let id = msg["id"]
    guard let method = msg["method"] as? String else {
        if id != nil { send(errorResponse(id, -32600, "缺少 method")) }
        continue
    }
    let params = (msg["params"] as? [String: Any]) ?? [:]

    do {
        let result = try dispatch(method, params)
        if let result = result, let id = id {
            send(["jsonrpc": "2.0", "id": id, "result": result])
        } else if let id = id {
            send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
        }
    } catch let e as CUAError {
        if let id = id {
            send(["jsonrpc": "2.0", "id": id,
                  "result": ["content": [["type": "text", "text": e.description]], "isError": true]])
        }
    } catch {
        if let id = id {
            send(["jsonrpc": "2.0", "id": id,
                  "result": ["content": [["type": "text", "text": "内部错误: \(error)"]], "isError": true]])
        }
    }
}
