//
//  cua-live — 实时画面回显（对话页角标小窗的数据源）
//
//  职责：盯住一个被操作的窗口，以固定帧率抓帧编码 JPEG，
//        对外提供 MJPEG 流，供前端 <img> 直接持续刷新。
//
//  为什么单独一个进程：
//    截图走 ScreenCaptureKit，属于常驻抓帧；放在一次性的工具进程里
//    会随每次 MCP 调用重建，帧不连续。这个进程常驻，状态只有一份。
//
//  为什么用 MJPEG 而不是 WebSocket：
//    multipart/x-mixed-replace 让浏览器自己维持刷新，前端零推流代码。
//    3fps 的延迟对「看 AI 在干什么」完全够。
//
//  端口固定 18901：跨端口的 <img> 不受 CORS 约束，
//    从而绕开宿主 webServer 的登录中间件（那条路会把请求拦成登录页）。
//

import Foundation
import AppKit
import ScreenCaptureKit
import Network
import ImageIO
import UniformTypeIdentifiers

let listenPort: UInt16 = 18901
/// 协议版本。cua-mcp 的 Live.ensureRunning 会拿它和期望值比对，
/// 不符就把这个进程杀掉重开——Mach-O 一旦加载就固定在内存里，
/// 二进制换了而老进程还活着时，不加这道校验就会一直在跑旧代码。
/// v2：加 `--watch-stdin`（存活绑父进程）。
let liveVersion = "2"
let frameInterval: TimeInterval = 1.0 / 3.0
// 预览卡显示宽度是 132 CSS px（见 client.js 的 CARD_W）。
// 抓 2 倍做 retina 就够，480 是 3.6 倍过采样，四分之三的像素编码完就扔。
let previewWidth: Double = 264
let jpegQuality: Double = 0.55
let boundary = "cualiveframe"

// MARK: - 目标窗口

struct Target {
    var pid: pid_t
    var appName: String
    var windowID: CGWindowID
    var expiresAt: Date
    /// 发起这次操作的会话。前端按它过滤，预览只出现在对应会话里。
    var session: String = ""
}

private var windowCache: [pid_t: (CGWindowID, Date)] = [:]

/// 取目标进程面积最大的可见普通层窗口。
/// CGWindowListCopyWindowInfo 是全局遍历，开销在百毫秒级，
/// 缓存 2 秒足够——被操作的窗口在短时间内不会换。
func windowID(for pid: pid_t) -> CGWindowID? {
    if let c = windowCache[pid], Date().timeIntervalSince(c.1) < 2.0 {
        return c.0
    }
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
        return nil
    }
    var best: (CGWindowID, CGFloat)?
    for info in list {
        guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
        guard let num = info[kCGWindowNumber as String] as? CGWindowID else { continue }
        if (info[kCGWindowLayer as String] as? Int ?? 0) != 0 { continue }
        let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let area = (b["Width"] as? CGFloat ?? 0) * (b["Height"] as? CGFloat ?? 0)
        if area < 100 { continue }
        if best == nil || area > best!.1 { best = (num, area) }
    }
    if let b = best {
        windowCache[pid] = (b.0, Date())
    }
    return best?.0
}

// MARK: - 抓帧与编码

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

/// SCShareableContent 是全局窗口枚举，单次几十到上百毫秒。
/// 每次抓帧都重新枚举的话，多窗口并发出帧会把自己拖死。
/// 缓存 2 秒：新窗口最晚 2 秒后可见，对 20 秒的目标 TTL 完全够。
/// 读写都收在同步函数里——NSLock 在 async 上下文里持有会报
/// “unavailable from asynchronous contexts”，等 await 跨过锁就是死锁。
private let contentLock = NSLock()
private var cachedContent: (content: SCShareableContent, at: Date)?
private let contentTTL: TimeInterval = 2.0

private func readCachedContent() -> SCShareableContent? {
    contentLock.lock()
    defer { contentLock.unlock() }
    guard let c = cachedContent, Date().timeIntervalSince(c.at) < contentTTL else { return nil }
    return c.content
}

private func storeContent(_ c: SCShareableContent) {
    contentLock.lock()
    cachedContent = (c, Date())
    contentLock.unlock()
}

func shareableContent(force: Bool = false) async throws -> SCShareableContent {
    if !force, let hit = readCachedContent() { return hit }
    let fresh = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: false
    )
    storeContent(fresh)
    return fresh
}

/// 抓一帧并缩到预览宽度。返回 nil 表示窗口消失、抓取失败或超时。
///
/// 全程 async，不占线程。上一版是同步函数里用信号量等异步结果，
/// 每个窗口会占住一条 GCD 线程最多 5 秒，多窗口时线程池贴着上限跑。
func capturePreview(
    windowID: CGWindowID, timeout: TimeInterval = 6
) async -> (data: Data, width: Int, height: Int)? {
    await withTaskGroup(of: (data: Data, width: Int, height: Int)?.self) { group in
        group.addTask { await captureOne(windowID: windowID) }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        // 谁先回来用谁。抓帧不响应取消，超时那条会自己在后台跑完并丢弃。
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func captureOne(windowID: CGWindowID) async -> (data: Data, width: Int, height: Int)? {
    do {
        var content = try await shareableContent()
        var win = content.windows.first(where: { $0.windowID == windowID })
        if win == nil {
            // 缓存里没有不代表窗口不存在。缓存 TTL 2 秒，
            // 新目标会在出首帧之前就被判成失效——找不到就强制刷新再判。
            content = try await shareableContent(force: true)
            win = content.windows.first(where: { $0.windowID == windowID })
        }
        guard let win else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: win)
        let cfg = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = max(1.0, Double(filter.pointPixelScale))
        let fullW = max(1.0, rect.width * scale)
        let fullH = max(1.0, rect.height * scale)
        let factor = min(1.0, previewWidth / fullW)
        cfg.width = max(1, Int(fullW * factor))
        cfg.height = max(1, Int(fullH * factor))
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let img = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: cfg
        )
        guard let enc = encodeJPEG(img, quality: jpegQuality) else { return nil }
        return (enc, img.width, img.height)
    } catch {
        return nil
    }
}

// MARK: - 状态与广播

final class LiveState {
    private let lock = NSLock()
    /// 同时被操作的多个窗口各存一份。键是 CGWindowID。
    private var targets: [CGWindowID: Target] = [:]
    private var frames: [CGWindowID: Frame] = [:]
    /// 正在抓的窗口。避免上一帧还没回来就又排一次，SCK 慢的时候会堆积。
    private var inFlight: Set<CGWindowID> = []
    /// 连续抓取失败次数。不能拿 frames 是否存在来计数：
    /// 清掉帧之后 frames 本来就不存在，计数永远起不来，
    /// 那个窗口会一直排在轮转队首，其他窗口全部停更直到 TTL 过期。
    private var missCounts: [CGWindowID: Int] = [:]
    /// 连续抓取失败的次数上限。1/3 秒一次，10 次约 3.3 秒——
    /// 太短的窗口（比如 5 次 = 1.7 秒）会把 SCK 偶发抽风的活窗口摘掉。
    private let missLimit = 10

    struct Frame {
        var jpeg: Data
        var seq: Int
        var width: Int
        var height: Int
    }

    /// 客户端订阅：一条连接只收它指定的窗口（nil 表示收任意窗口）。
    /// lastSend 用来兜底清理收不到 FIN 的死连接。
    private var clients: [(conn: NWConnection, window: CGWindowID, lastSend: Date)] = []

    func setTarget(pid: pid_t, appName: String, ttl: Double, explicit: CGWindowID?, session: String = "") {
        guard let wid = explicit ?? windowID(for: pid) else { return }
        lock.lock()
        let existed = targets[wid] != nil
        targets[wid] = Target(
            pid: pid,
            appName: appName,
            windowID: wid,
            expiresAt: Date().addingTimeInterval(ttl),
            session: session
        )
        lock.unlock()
        if !existed {
            FileHandle.standardError.write(Data("[cua-live] 新增目标 \(appName) pid=\(pid) win=\(wid)\n".utf8))
        }
    }

    func clear() {
        lock.lock()
        targets.removeAll()
        frames.removeAll()
        missCounts.removeAll()
        inFlight.removeAll()
        let victims = clients.map { $0.conn }
        clients.removeAll()
        lock.unlock()
        for c in victims { c.cancel() }
    }

    /// 清理过期目标与失效帧。
    private func sweepLocked() {
        let now = Date()
        for (wid, t) in targets where now >= t.expiresAt {
            targets.removeValue(forKey: wid)
            frames.removeValue(forKey: wid)
            missCounts.removeValue(forKey: wid)
        }
    }

    /// 当前所有有效目标。
    func activeTargets() -> [Target] {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked()
        return targets.values.sorted { $0.windowID < $1.windowID }
    }

    func activeTarget(window: CGWindowID?) -> Target? {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked()
        if let w = window { return targets[w] }
        return targets.values.max { $0.expiresAt < $1.expiresAt }
    }

    /// 一次 tick 里所有该抓的窗口。调用方抓完调 endCapture(window:)。
    /// 上一版是「一次只放一个窗口出去」，N 个窗口时每个窗口 1/(3N) 帧/秒：
    /// 五个窗口就掉到 1.7 秒一帧，画面看着是卡的。
    /// 现在每帧窗各自并发，只有一个窗口时也不比原来慢。
    func beginCaptureAll() -> [Target] {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked()
        var batch: [Target] = []
        for t in targets.values where !inFlight.contains(t.windowID) {
            inFlight.insert(t.windowID)
            batch.append(t)
        }
        return batch
    }

    func endCapture(window: CGWindowID) {
        lock.lock()
        inFlight.remove(window)
        lock.unlock()
    }

    func noteMiss(window: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        let n = (missCounts[window] ?? 0) + 1
        if n >= missLimit {
            // 连续抓不到说明窗口没了。直接摘出目标，
            // 否则它会一直占着轮转名额，其他窗口冻到 TTL 过期为止。
            targets.removeValue(forKey: window)
            frames.removeValue(forKey: window)
            missCounts.removeValue(forKey: window)
            FileHandle.standardError.write(
                Data("[cua-live] 移除失效目标 win=\(window)（连续 \(n) 次抓取失败）\n".utf8)
            )
        } else {
            missCounts[window] = n
        }
    }

    func publish(_ jpeg: Data, target: Target, width: Int, height: Int) {
        lock.lock()
        guard let current = targets[target.windowID], Date() < current.expiresAt else {
            lock.unlock()
            return
        }
        let seq = (frames[target.windowID]?.seq ?? 0) + 1
        frames[target.windowID] = Frame(jpeg: jpeg, seq: seq, width: width, height: height)
        missCounts[target.windowID] = 0
        let now = Date()
        for i in clients.indices where clients[i].window == target.windowID {
            clients[i].lastSend = now
        }
        let recipients = clients
            .filter { $0.window == target.windowID }
            .map { $0.conn }
        lock.unlock()

        guard !recipients.isEmpty else { return }
        var chunk = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        chunk.append(jpeg)
        chunk.append(Data("\r\n".utf8))
        for conn in recipients {
            // 发送失败说明对端已经走了，立刻摘掉，别等状态回调——
            // 长连接上有时等不到 .cancelled，viewers 就会虚高不降。
            conn.send(content: chunk, completion: .contentProcessed { err in
                if err != nil { self.removeClient(conn) }
            })
        }
    }

    func addClient(_ conn: NWConnection, window: CGWindowID) {
        lock.lock()
        clients.append((conn, window, Date()))
        // 只给这个窗口的帧。之前对「没指定窗口」的连接会退到「最新的一帧」，
        // 结果订阅 A 的连接在首帧到达前先收到 B 的画面——跨会话直接串画面。
        // 现在窗口号是必填的，这条路已经不存在了。
        let seed = frames[window]?.jpeg
        lock.unlock()
        if let frame = seed {
            var chunk = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n".utf8)
            chunk.append(frame)
            chunk.append(Data("\r\n".utf8))
            conn.send(content: chunk, completion: .contentProcessed { _ in })
        }
    }

    func removeClient(_ conn: NWConnection) {
        lock.lock()
        clients.removeAll { $0.conn === conn }
        lock.unlock()
    }

    /// 清掉已经没人需要的订阅连接：订阅的窗口早就不在目标里了，
    /// 或者长时间一帧都没发出去（对端悄悄断了但没给 FIN）。
    /// 返回的连接由调用方在锁外 cancel。
    func sweepDeadClients(idle: TimeInterval = 600) -> [NWConnection] {
        lock.lock()
        let now = Date()
        var dead: [NWConnection] = []
        var keep: [(conn: NWConnection, window: CGWindowID, lastSend: Date)] = []
        for c in clients {
            // 订阅的窗口已经不在目标里了：这条流不会再有任何帧
            let orphan = targets[c.window] == nil
            let stale = now.timeIntervalSince(c.lastSend) > idle
            if orphan || stale {
                dead.append(c.conn)
            } else {
                keep.append(c)
            }
        }
        let dropped = clients.count - keep.count
        clients = keep
        lock.unlock()
        if dropped > 0 {
            FileHandle.standardError.write(
                Data("[cua-live] 清理 \(dropped) 条失效订阅连接\n".utf8)
            )
        }
        return dead
    }

    func clientCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clients.count
    }

    func frameInfo(window: CGWindowID?) -> (bytes: Int, seq: Int, width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        let f: Frame?
        if let w = window { f = frames[w] } else { f = frames.values.max { $0.seq < $1.seq } }
        guard let f = f else { return (0, 0, 0, 0) }
        return (f.jpeg.count, f.seq, f.width, f.height)
    }

    /// 每个目标加上帧信息，供 /status 一次性返回。
    func snapshot(session: String?) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked()
        // 最近被操作的排前面：同时操作多个应用时，最上面应该是刚动过的那个
        var list = targets.values.sorted { $0.expiresAt > $1.expiresAt }
        // 严格按会话过滤：空 session 的目标不认领给任何会话。
        // 否则外部脚本（不带会话标识）操作的应用会串到别人的项目里，
        // 这比"那个会话自己看不到预览"更糟。
        if let s = session, !s.isEmpty {
            list = list.filter { $0.session == s }
        }
        return list.map { t in
            let f = frames[t.windowID]
            return [
                "app": t.appName,
                "pid": Int(t.pid),
                "window": Int(t.windowID),
                "session": t.session,
                "alive": f != nil,
                "bytes": f?.jpeg.count ?? 0,
                "seq": f?.seq ?? 0,
                "width": f?.width ?? 0,
                "height": f?.height ?? 0,
            ]
        }
    }
}

let state = LiveState()
let workQueue = DispatchQueue(label: "cua.live.server")

// CGWindowList / SCK 都要求进程已建立 WindowServer 连接。
// 纯 CLI 进程不建这个连接，首次在多线程里调 CG API 会直接断言
// `CGS_REQUIRE_INIT`（2026-10-27 踩过，表现为 Abort trap 6）。
// 启动时在主线程摸一次 CGMainDisplayID，把连接建起来。
_ = CGMainDisplayID()

// MARK: - 自检
//
// 这层的坑（死窗口占住抓帧名额、并发被串行化、端口被旧实例占着）
// 都看不见也报不出来，只能靠外部 curl 猜。做成自检才能回归。

func portIsFree(_ port: UInt16, host: String = "127.0.0.1") -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr(host))
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return bound == 0
}

func runSelfTest() -> Int32 {
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failed += 1 }
    }

    check("screen capture preflight", CGPreflightScreenCaptureAccess())
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]] ?? []
    check("window enumeration", !windows.isEmpty, "\(windows.count) 个可见窗口")

    // 调度器：两个目标必须一起进批次，否则多窗口时互相排队
    let probe = LiveState()
    probe.setTarget(pid: getpid(), appName: "selftest-a", ttl: 60, explicit: 900001)
    probe.setTarget(pid: getpid(), appName: "selftest-b", ttl: 60, explicit: 900002)
    let batch = probe.beginCaptureAll()
    check("并发调度", batch.count == 2, "批次 \(batch.count) 个")
    check("同窗口不重入", probe.beginCaptureAll().isEmpty)
    for t in batch { probe.endCapture(window: t.windowID) }
    check("抓完可再排", probe.beginCaptureAll().count == 2)

    // 连续抓不到的目标必须被摘掉，否则会永久占着名额把别的窗口饿死
    probe.clear()
    probe.setTarget(pid: getpid(), appName: "ghost", ttl: 60, explicit: 900003)
    for _ in 0..<10 { probe.noteMiss(window: 900003) }
    check("失效目标摘除", probe.snapshot(session: nil).isEmpty)

    // 端口只报告不判失败：已有实例在跑时被占用是正常的
    print("info 端口 \(listenPort) \(portIsFree(listenPort) ? "空闲" : "已被占用（可能已有实例在跑）")")

    print(failed == 0 ? "SELFTEST PASS" : "SELFTEST FAIL (\(failed) 项)")
    return failed == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}


// MARK: - 聚焦目标窗口
//
// 点击对话页右上角的小窗 → 直接跳到被操作的那个窗口。
// 与后台操作相反：这是用户主动要求，就该把窗口提到前台。

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

func raiseWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
    guard AXIsProcessTrusted() else { return false }
    let app = AXUIElementCreateApplication(pid)
    guard let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
    for w in wins {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(w, &wid) == .success, wid == windowID else { continue }
        return AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success
    }
    return false
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
    return v
}

// MARK: - HTTP

/// 记录请求，用来判断前端到底有没有在轮询（netstat 抓不到 fetch 的短连接）。
enum RequestLog {
    static let path = "/tmp/cua-live-requests.log"
    /// 默认一个字节都不写。这个日志是排查「前端到底有没有在轮询」用的，
    /// 仓库里没有任何读取方；之前无条件写，等于在正式版里常开一条只写不读的日志。
    /// 要用就 `DSH_CUA_LIVE_LOG=1` 起 cua-live。
    static let enabled = ProcessInfo.processInfo.environment["DSH_CUA_LIVE_LOG"] == "1"
    static let lock = NSLock()
    static let maxBytes = 512 * 1024
    static func note(_ p: String) {
        guard enabled else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(Date().timeIntervalSince1970) \(p)\n"
        // /status 每 1.5 秒一条，不封顶会一直写下去。到 512KB 就整个重开。
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > maxBytes {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

func httpResponse(_ status: String, _ contentType: String, _ body: Data) -> Data {
    var head = "HTTP/1.1 \(status)\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Access-Control-Allow-Origin: *\r\n"
    head += "Cache-Control: no-store\r\n"
    head += "Connection: close\r\n\r\n"
    var out = Data(head.utf8)
    out.append(body)
    return out
}

func jsonResponse(_ obj: [String: Any]) -> Data {
    let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return httpResponse("200 OK", "application/json; charset=utf-8", body)
}

/// 明确的拒绝回包。用状态码说清楚，别伪装成 200 让调用方以为成功。
func textResponse(_ status: String, _ body: String) -> Data {
    httpResponse(status, "text/plain; charset=utf-8", Data((body + "\n").utf8))
}

func mjpegHeader() -> Data {
    var head = "HTTP/1.1 200 OK\r\n"
    head += "Content-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\n"
    head += "Access-Control-Allow-Origin: *\r\n"
    head += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
    head += "Pragma: no-cache\r\n"
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8)
}

func parseQuery(_ path: String) -> (String, [String: String]) {
    guard let qIndex = path.firstIndex(of: "?") else { return (path, [:]) }
    let route = String(path[path.startIndex..<qIndex])
    var params: [String: String] = [:]
    for pair in path[path.index(after: qIndex)...].split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        guard kv.count == 2 else { continue }
        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
        let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
        params[key] = value
    }
    return (route, params)
}

func handleConnection(_ conn: NWConnection) {
    conn.start(queue: workQueue)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, error in
        guard error == nil, let data, !data.isEmpty else {
            conn.cancel()
            return
        }
        let request = String(data: data, encoding: .utf8) ?? ""
        let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
        let pieces = firstLine.split(separator: " ")
        let method = pieces.count > 0 ? String(pieces[0]) : ""
        let rawPath = pieces.count > 1 ? String(pieces[1]) : "/"
        let (route, params) = parseQuery(rawPath)

        // 浏览器发起的请求会带 Sec-Fetch-Site。外站页面里嵌一个 <img> 或 <form>
        // 就能打到这里的 GET 接口，而 /target 能把任意应用注册成捕获目标、
        // /focus 能把窗口抬到最前——这些都不该由别的网站触发。
        // curl / cua-mcp 这类非浏览器调用没有这个头，视为本地可信调用放行。
        let fetchSite = request
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("sec-fetch-site:") }?
            .split(separator: ":", maxSplits: 1).last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let crossSite = fetchSite == "cross-site"

        switch (method, route) {
        case (_, "/status"):
            RequestLog.note(rawPath)
            let list = state.snapshot(session: params["session"])
            conn.send(content: jsonResponse([
                // 版本握手用：cua-mcp 按它判断要不要杀掉这个进程重开
                "version": liveVersion,
                "active": !list.isEmpty,
                "targets": list,
                "viewers": state.clientCount(),
            ]), completion: .contentProcessed { _ in conn.cancel() })

        case (_, "/focus"):
            guard !crossSite else {
                conn.send(content: textResponse("403 Forbidden", "跨站请求不能操作窗口"),
                          completion: .contentProcessed { _ in conn.cancel() })
                break
            }
            guard let t = state.activeTarget(window: params["window"].flatMap { CGWindowID($0) }) else {
                conn.send(content: jsonResponse(["ok": false, "reason": "当前没有操作目标"]),
                          completion: .contentProcessed { _ in conn.cancel() })
                break
            }
            // 先把目标窗口在应用内提到最前，再激活应用——
            // 多窗口应用只激活不 raise 的话，用户看到的是别的窗口。
            let raised = raiseWindow(pid: t.pid, windowID: t.windowID)
            let activated = NSRunningApplication(processIdentifier: t.pid)?
                .activate(options: [.activateIgnoringOtherApps]) ?? false
            conn.send(content: jsonResponse([
                "ok": activated || raised,
                "app": t.appName,
                "raised": raised,
                "activated": activated,
            ]), completion: .contentProcessed { _ in conn.cancel() })

        case (_, "/target"):
            guard !crossSite else {
                conn.send(content: textResponse("403 Forbidden", "跨站请求不能注册捕获目标"),
                          completion: .contentProcessed { _ in conn.cancel() })
                break
            }
            let pid = pid_t(params["pid"] ?? "") ?? 0
            let app = params["app"] ?? ""
            let ttl = Double(params["ttl"] ?? "") ?? 20
            if pid > 0 {
                let explicit = params["window"].flatMap { CGWindowID($0) }
                state.setTarget(pid: pid, appName: app, ttl: ttl,
                                explicit: explicit, session: params["session"] ?? "")
            }
            let t = state.activeTarget(window: params["window"].flatMap { CGWindowID($0) })
            conn.send(content: jsonResponse([
                "ok": t != nil,
                "app": t?.appName ?? "",
                "window": t.map { Int($0.windowID) } ?? 0,
            ]), completion: .contentProcessed { _ in conn.cancel() })

        case (_, "/clear"):
            guard !crossSite else {
                conn.send(content: textResponse("403 Forbidden", "跨站请求不能清空目标"),
                          completion: .contentProcessed { _ in conn.cancel() })
                break
            }
            state.clear()
            conn.send(content: jsonResponse(["ok": true]),
                       completion: .contentProcessed { _ in conn.cancel() })

        case (_, "/live.mjpg"):
            // win 必填。原来不带 win 的连接会收到「最新目标」的帧，
            // 于是本机任意页面写一行 <img src="/live.mjpg"> 就能看到
            // AI 正在操作的那个窗口，连窗口号都不用知道。
            // 前端一直是带 win 的，这条路没有正常使用者。
            guard let windowParam = params["win"], let window = CGWindowID(windowParam) else {
                conn.send(content: textResponse("400 Bad Request", "缺少 win 参数：/live.mjpg?win=<CGWindowID>"),
                          completion: .contentProcessed { _ in conn.cancel() })
                break
            }
            conn.send(content: mjpegHeader(), completion: .contentProcessed { _ in })
            state.addClient(conn, window: window)
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .failed, .cancelled:
                    state.removeClient(conn)
                default:
                    break
                }
            }
            // 必须持续读。这是无限响应，浏览器关掉页面时发的是 FIN，
            // 不读就永远收不到 .cancelled，viewers 只涨不降（实测漏到 6）。
            // 读到的数据本身没用，丢弃，只看连接是否还在。
            func drain() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
                    if error != nil || isComplete {
                        state.removeClient(conn)
                        conn.cancel()
                        return
                    }
                    drain()
                }
            }
            drain()

        default:
            conn.send(content: httpResponse(
                "404 Not Found", "application/json; charset=utf-8",
                Data("{\"error\":\"not found\"}".utf8)
            ), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// MARK: - 抓帧循环

let pumpQueue = DispatchQueue(label: "cua.live.pump")
let pumpTimer = DispatchSource.makeTimerSource(queue: pumpQueue)
pumpTimer.schedule(deadline: .now() + 0.1, repeating: frameInterval)
pumpTimer.setEventHandler {
    // 顺手清掉失效订阅，viewers 才不会是虚数
    for dead in state.sweepDeadClients() { dead.cancel() }
    // 每个窗口各自跑，互不排队。抓帧是 async 的，直接在 Task 里等，
    // 不占线程，也不会像上一版那样把 pump 队列串起来。
    let batch = state.beginCaptureAll()
    guard !batch.isEmpty else { return }
    for target in batch {
        Task {
            defer { state.endCapture(window: target.windowID) }
            if let frame = await capturePreview(windowID: target.windowID) {
                state.publish(frame.data, target: target, width: frame.width, height: frame.height)
            } else {
                state.noteMiss(window: target.windowID)
            }
        }
    }
}
pumpTimer.resume()

// MARK: - 启动

guard let port = NWEndpoint.Port(rawValue: listenPort) else {
    FileHandle.standardError.write(Data("cua-live: 端口非法\n".utf8))
    exit(1)
}

do {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    // 只绑回环。NWParameters.tcp 默认监听 0.0.0.0/::，而本服务能做的事是：
    //   /target?pid=<任意应用>  把它注册成捕获目标
    //   /live.mjpg              拉该窗口的实时画面
    //   /focus                  把窗口提到最前
    // 全程没有鉴权，而 cua-live 是带屏幕录制授权跑的。绑在通配地址上，
    // 同网段任何人（或本机任意网页）都能把屏幕画面拉走。实测过 lsof 是 `*:18901`。
    params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
    let listener = try NWListener(using: params)
    listener.newConnectionHandler = { conn in handleConnection(conn) }
    listener.stateUpdateHandler = { st in
        if case let .failed(err) = st {
            FileHandle.standardError.write(Data("cua-live: 监听失败 \(err)\n".utf8))
            exit(1)
        }
    }
    listener.start(queue: workQueue)
    FileHandle.standardError.write(
        Data("[cua-live] MJPEG 就绪 http://127.0.0.1:\(listenPort)/live.mjpg screenRecording=\(CGPreflightScreenCaptureAccess())\n".utf8)
    )
} catch {
    FileHandle.standardError.write(Data("cua-live: 启动失败 \(error)\n".utf8))
    exit(1)
}

signal(SIGPIPE, SIG_IGN)

// MARK: - 存活绑在开它的那个进程上

/// `--watch-stdin`：stdin 是 cua-mcp 递过来的管子。
/// 父进程一消失（正常退出、崩溃、被 SIGKILL），写端被内核回收，
/// 这里 read 立刻返回 0，跟着退出——不留一个没人认领的常驻进程，
/// 占着 18901、还带着屏幕录制授权在抓帧。
///
/// 为什么做成显式参数而不是默认行为：手动在终端跑的时候 stdin 是 tty，
/// 默认行为会让「终端状态」悄悄决定进程生死；接 /dev/null 更会一起来就退。
/// 有这根管子才认这根管子。
if CommandLine.arguments.contains("--watch-stdin") {
    Thread.detachNewThread {
        var byte: UInt8 = 0
        while true {
            let n = read(0, &byte, 1)
            if n > 0 { continue }       // 没人往这里写，读到什么就丢掉
            if n < 0 && errno == EINTR { continue }
            exit(0)                      // EOF 或读错：当作父进程没了
        }
    }
}

// RunLoop 而不是 dispatchMain：SCScreenshotManager 的 async 实现会 hop 主 actor，
// dispatchMain() 让主线程进入 dispatch 队列后那些 continuation 永远不执行，
// 表现是抓帧静默返回 nil（2026-10-27 踩过）。
RunLoop.main.run()
