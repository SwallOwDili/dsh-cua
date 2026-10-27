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
let frameInterval: TimeInterval = 1.0 / 3.0
let previewWidth: Double = 480
let jpegQuality: Double = 0.5
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

/// 抓一帧并缩到预览宽度。返回 nil 表示窗口消失或抓取失败。
func capturePreview(windowID: CGWindowID) -> (data: Data, width: Int, height: Int)? {
    let sem = DispatchSemaphore(value: 0)
    var out: (Data, Int, Int)?
    Task {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            if let win = content.windows.first(where: { $0.windowID == windowID }) {
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
                if let enc = encodeJPEG(img, quality: jpegQuality) {
                    out = (enc, img.width, img.height)
                }
            }
        } catch {
            out = nil
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 5)
    return out
}

// MARK: - 状态与广播

final class LiveState {
    private let lock = NSLock()
    /// 同时被操作的多个窗口各存一份。键是 CGWindowID。
    private var targets: [CGWindowID: Target] = [:]
    private var frames: [CGWindowID: Frame] = [:]
    private var capturing = false
    private let missLimit = 5

    struct Frame {
        var jpeg: Data
        var seq: Int
        var width: Int
        var height: Int
        var missStreak: Int
    }

    /// 客户端订阅：一条连接只收它指定的窗口（nil 表示收任意窗口）。
    private var clients: [(conn: NWConnection, window: CGWindowID?)] = []

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

    /// 挑一个还没在抓的窗口交出去。调用方抓完调 endCapture。
    func beginCapture() -> Target? {
        lock.lock()
        defer { lock.unlock() }
        sweepLocked()
        if capturing { return nil }
        // 轮转：优先抓没有帧或帧最旧的窗口
        guard let next = targets.values.min(by: {
            (frames[$0.windowID]?.seq ?? -1) < (frames[$1.windowID]?.seq ?? -1)
        }) else { return nil }
        capturing = true
        return next
    }

    func endCapture() {
        lock.lock()
        capturing = false
        lock.unlock()
    }

    func noteMiss(window: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        guard var f = frames[window] else { return }
        f.missStreak += 1
        if f.missStreak >= missLimit {
            frames.removeValue(forKey: window)
        } else {
            frames[window] = f
        }
    }

    func publish(_ jpeg: Data, target: Target, width: Int, height: Int) {
        lock.lock()
        guard let current = targets[target.windowID], Date() < current.expiresAt else {
            lock.unlock()
            return
        }
        let seq = (frames[target.windowID]?.seq ?? 0) + 1
        frames[target.windowID] = Frame(jpeg: jpeg, seq: seq, width: width, height: height, missStreak: 0)
        let recipients = clients.filter { $0.window == nil || $0.window == target.windowID }
        lock.unlock()

        guard !recipients.isEmpty else { return }
        var chunk = Data("--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        chunk.append(jpeg)
        chunk.append(Data("\r\n".utf8))
        for c in recipients { c.conn.send(content: chunk, completion: .contentProcessed { _ in }) }
    }

    func addClient(_ conn: NWConnection, window: CGWindowID?) {
        lock.lock()
        clients.append((conn, window))
        let seed = window.flatMap { frames[$0]?.jpeg }
            ?? frames.values.max { $0.seq < $1.seq }?.jpeg
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
        // 带 session 查询就只返回该会话的目标；空 session 的旧目标不认领
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

        switch (method, route) {
        case (_, "/status"):
            let list = state.snapshot(session: params["session"])
            conn.send(content: jsonResponse([
                "active": !list.isEmpty,
                "targets": list,
                "viewers": state.clientCount(),
            ]), completion: .contentProcessed { _ in conn.cancel() })

        case (_, "/focus"):
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
            state.clear()
            conn.send(content: jsonResponse(["ok": true]),
                       completion: .contentProcessed { _ in conn.cancel() })

        case (_, "/live.mjpg"):
            conn.send(content: mjpegHeader(), completion: .contentProcessed { _ in })
            state.addClient(conn, window: params["win"].flatMap { CGWindowID($0) })
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .failed, .cancelled:
                    state.removeClient(conn)
                default:
                    break
                }
            }

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
    guard let target = state.beginCapture() else { return }
    defer { state.endCapture() }
    if let frame = capturePreview(windowID: target.windowID) {
        state.publish(frame.data, target: target, width: frame.width, height: frame.height)
    } else {
        state.noteMiss(window: target.windowID)
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
    let listener = try NWListener(using: params, on: port)
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
// RunLoop 而不是 dispatchMain：SCScreenshotManager 的 async 实现会 hop 主 actor，
// dispatchMain() 让主线程进入 dispatch 队列后那些 continuation 永远不执行，
// 表现是抓帧静默返回 nil（2026-10-27 踩过）。
RunLoop.main.run()
