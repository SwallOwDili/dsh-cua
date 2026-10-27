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
/// 元素条目：除了 AX 引用，还带一条「结构路径」指纹。
///
/// AXUIElement 是运行期引用，界面一变就可能失效；而模型手里的 elementID
/// 必须在多步操作中保持可用。路径指纹用来在失效后重新定位同一个控件：
/// 形如 `AXWindow[0]/AXGroup[1]/AXButton[2]`，每段是 role 加同类兄弟序号。
struct ElementEntry {
    let element: AXUIElement
    let path: String
    let role: String
    let title: String
}

var registries: [pid_t: [Int: ElementEntry]] = [:]
/// 每个 pid 的下一个可用 elementID（单调递增，仅用于新出现的元素）
var nextIDs: [pid_t: Int] = [:]
/// path → id，用于跨快照复用 id：同一个控件在两次快照里拿到同一个编号
var idByPath: [pid_t: [String: Int]] = [:]
/// 上一次快照的 path → (id, 行内容)，增量输出据此只报变化
struct BaselineEntry {
    let id: Int
    let line: String
}
var baselines: [pid_t: [String: BaselineEntry]] = [:]
/// 每个 pid 的第一棵树。累积 diff（cumulative）拿它当基准，
/// 对应 Codex 的 "cumulative diff from the initial accessibility tree"。
var initialBaselines: [pid_t: [String: BaselineEntry]] = [:]

/// 元素失效监听。对应 Codex 的 UIElementTreeInvalidationMonitor。
///
/// 与 Codex 的差异要说清：它用监听做到「动作执行前校验目标仍有效」，
/// 我这边 `element()` 本来就是每次读一次 role 判断死活，
/// 所以监听在当前实现里的实际收益是**让 CGWindowID 缓存立即失效**——
/// 窗口开关之后不会再拿旧窗口号去截图。监听本身不需要它也能正确工作。
var invalidationCount: [pid_t: Int] = [:]
var axObservers: [pid_t: AXObserver] = [:]

let invalidationCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let pid = pid_t(Int(bitPattern: refcon))
    invalidationCount[pid, default: 0] += 1
    // 窗口结构变了，缓存的 CGWindowID 可能指向已经消失的窗口——
    // 直接清掉，下次按需重取，避免截图截到错窗口。
    windowIDCache.removeValue(forKey: pid)
}

func installInvalidationMonitor(pid: pid_t) {
    guard axObservers[pid] == nil else { return }
    var observer: AXObserver?
    guard AXObserverCreate(pid, invalidationCallback, &observer) == .success,
          let obs = observer else { return }
    let app = AXUIElementCreateApplication(pid)
    let refcon = UnsafeMutableRawPointer(bitPattern: Int(pid))
    for note in [
        kAXUIElementDestroyedNotification,
        kAXWindowCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXLayoutChangedNotification,
    ] {
        _ = AXObserverAddNotification(obs, app, note as CFString, refcon)
    }
    CFRunLoopAddSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(obs),
        .defaultMode
    )
    axObservers[pid] = obs
}



// MARK: - 运行时配置（热读）
//
// index.js 把 settings 系统的 `cua` 命名空间落到 ~/.dsh/dsh-cua.config.json，
// 这里按 mtime 热读：设置页改完立即生效，不需要重启 harness。
// 文件不存在时全部走默认值，与 schema 的 default 保持一致。


// MARK: - 应用策略
//
// Codex 那套是 MDM 下发的组织策略；本机场景只需要一张表：
// 白名单（只允许这些）优先于黑名单（禁止这些），都按 bundleID 精确匹配。
// 命中就在工具分发层拒绝，不让动作落到目标应用上。

func policyDecision(for app: AppRef) -> String? {
    let cfg = CuaConfig.current()
    let blocked = cfg.deniedBundleIDs
    let allowed = cfg.allowedBundleIDs
    if !allowed.isEmpty, !allowed.contains(app.bundleID) {
        return "\(app.name)（\(app.bundleID)）不在允许列表内；当前只允许: " + allowed.joined(separator: ", ")
    }
    if blocked.contains(app.bundleID) {
        return "\(app.name)（\(app.bundleID)）在禁止列表内，操作被拒绝"
    }
    return nil
}

struct RuntimeConfig: Decodable {
    var browserCdpPort: Int = 0
    var browserCdpHost: String = "127.0.0.1"
    var overlayEnabled: Bool = true
    var overlayTtlSeconds: Double = 20
    var backgroundSilence: Bool = true
    var scrollStepPx: Int = 40
    var maxElements: Int = 4000
    var syntheticActivate: Bool = true
    var deniedBundleIDs: [String] = []
    var allowedBundleIDs: [String] = []

    // 合成 Decodable 对缺失字段会抛错（属性默认值不参与），
    // 而配置文件允许只写部分键，所以逐字段 decodeIfPresent。
    // 手写 init(from:) 后编译器不再合成 CodingKeys，必须显式声明。
    enum CodingKeys: String, CodingKey {
        case browserCdpPort, browserCdpHost, overlayEnabled, overlayTtlSeconds
        case backgroundSilence, scrollStepPx, maxElements
        case syntheticActivate, deniedBundleIDs, allowedBundleIDs
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
        syntheticActivate = (try? c.decodeIfPresent(Bool.self, forKey: .syntheticActivate)).flatMap { $0 } ?? true
        deniedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .deniedBundleIDs)).flatMap { $0 } ?? []
        allowedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .allowedBundleIDs)).flatMap { $0 } ?? []
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

func actionNames(of el: AXUIElement) -> [String] {
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
    var text: String
    let count: Int
    let focused: String?
    var unchanged = 0
    var changed = 0
    var added = 0
    var removed = 0
    var isDiff = false
}

func captureTree(pid: pid_t, appName: String, diffMode: String = "none") -> Snapshot {
    installInvalidationMonitor(pid: pid)
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

    var registry: [Int: ElementEntry] = [:]
    var counter = nextIDs[pid] ?? 1
    var lines: [String] = []
    var collected: [(path: String, id: Int, depth: Int, line: String)] = []
    var visited = 0
    var focusedLine: String?

    // 跨快照复用 id：同一个结构路径拿同一个编号，模型可以继续用旧 id。
    let previousPaths = idByPath[pid] ?? [:]
    var pathsInUse: [String: Int] = [:]

    struct Frame { let el: AXUIElement; let depth: Int; let path: String; let roleIndex: Int }
    var stack: [Frame] = [Frame(el: start, depth: 0, path: "", roleIndex: 0)]

    while let f = stack.popLast() {
        let cap = CuaConfig.current().maxElements
        if visited >= cap { lines.append("... (达到节点上限 \(cap)，已截断)"); break }
        if f.depth > maxDepth { continue }
        visited += 1

        let role = strAttr(f.el, kAXRoleAttribute as String) ?? "AXUnknown"
        let title = strAttr(f.el, kAXTitleAttribute as String) ?? ""

        // 路径 = 父路径 + role + 同 role 兄弟序号。序号由父节点的入栈时算好，
        // 比 AX 的原始下标稳定：兄弟里插进别的 role 不会让整条路径错位。
        let path = f.path + "/" + role + "[" + String(f.roleIndex) + "]"

        let id: Int
        if let reuse = previousPaths[path] ?? pathsInUse[path] {
            id = reuse
        } else {
            id = counter
            counter += 1
        }
        pathsInUse[path] = id
        registry[id] = ElementEntry(element: f.el, path: path, role: role, title: title)
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

        let acts = actionNames(of: f.el)
        if !acts.isEmpty {
            let interesting = acts.filter { $0 != kAXPressAction as String || acts.count > 1 }
            if !interesting.isEmpty {
                parts.append("actions=[\(interesting.joined(separator: ","))]")
            }
        }

        let line = String(repeating: indentUnit, count: f.depth) + parts.joined(separator: " ")
        lines.append(line)
        collected.append((path: path, id: id, depth: f.depth, line: line))
        if isFocused, focusedLine == nil {
            focusedLine = line.trimmingCharacters(in: .whitespaces)
        }

        let kids = childrenOf(f.el)
        var roleCount: [String: Int] = [:]
        var childFrames: [Frame] = []
        childFrames.reserveCapacity(kids.count)
        for k in kids {
            let kr = strAttr(k, kAXRoleAttribute as String) ?? "AXUnknown"
            let idx = roleCount[kr] ?? 0
            roleCount[kr] = idx + 1
            childFrames.append(Frame(el: k, depth: f.depth + 1, path: path, roleIndex: idx))
        }
        for cf in childFrames.reversed() {
            stack.append(cf)
        }
    }

    registries[pid] = registry
    nextIDs[pid] = counter
    idByPath[pid] = pathsInUse

    // 增量输出：与上一版基线逐 path 比对。
    // 未变化的节点不重复吐——id 已经稳定，模型手上还有上一轮那个编号。
    // cumulative 与第一棵树比，auto 与上一次比
    let previous: [String: BaselineEntry]
    if diffMode == "cumulative" {
        previous = initialBaselines[pid] ?? [:]
    } else {
        previous = baselines[pid] ?? [:]
    }
    var fresh: [String: BaselineEntry] = [:]
    fresh.reserveCapacity(collected.count)
    for item in collected {
        // 缩进后的整行（含 id）用于展示；比对时剥掉 id，否则 id 复用也会被判成变化
        let content = item.line.replacingOccurrences(
            of: "[\(item.id)]",
            with: "[]"
        )
        fresh[item.path] = BaselineEntry(id: item.id, line: content)
    }

    var header = "App: \(appName) (pid \(pid))\n"
    if let fl = focusedLine { header += "Focused: \(fl)\n" }
    header += "Elements: \(registry.count)\n"

    var snap = Snapshot(text: "", count: registry.count, focused: focusedLine)
    snap.unchanged = 0
    snap.changed = 0
    snap.added = 0
    snap.removed = 0
    snap.isDiff = false

    if diffMode != "none", !previous.isEmpty {
        var out: [String] = []
        var seen: Set<String> = []
        var removedIDs: [Int] = []
        for item in collected {
            seen.insert(item.path)
            let content = fresh[item.path]!.line
            guard let old = previous[item.path] else {
                snap.added += 1
                out.append("+ " + item.line.trimmingCharacters(in: .whitespaces))
                continue
            }
            if old.line == content {
                snap.unchanged += 1
                continue
            }
            snap.changed += 1
            // 紧凑标记：变化项只给「属性旧值→新值」，不重读整行
            let delta = attributeDelta(from: old.line, to: item.line)
            out.append("~ " + item.line.trimmingCharacters(in: .whitespaces) + "  " + delta)
        }
        for (path, old) in previous where !seen.contains(path) {
            snap.removed += 1
            removedIDs.append(old.id)
            _ = path
        }
        // 移除项按 ID 区间汇总：Codex 那侧 axTreeDiffingRemovedElementIDRanges 的做法。
        // 逐条给 path + 原文，界面大改一次就是几十行，压成区间只要一行。
        if !removedIDs.isEmpty {
            out.append("- 已移除 " + String(removedIDs.count) + " 项: ID " + compressRanges(removedIDs))
        }

        header += "Diff: 未变 \(snap.unchanged)，变化 \(snap.changed)，新增 \(snap.added)，移除 \(snap.removed)\n"
        if out.isEmpty {
            header += "（界面无变化）\n"
        } else {
            if diffMode == "cumulative" {
            header += "~ 变化，+ 新增，- 移除；基准是最初那棵树。全量用 diff=none。\n"
        } else {
            header += "~ 变化，+ 新增，- 移除；未变节点沿用上轮 elementID。全量用 diff=none。\n"
        }
        }
        snap.text = header + out.joined(separator: "\n")
        snap.isDiff = true
    } else {
        snap.text = header + lines.joined(separator: "\n")
    }

    baselines[pid] = fresh
    // 第一棵树只记一次；累积模式一直以它为基准
    if initialBaselines[pid] == nil {
        initialBaselines[pid] = fresh
    }
    return snap
}

/// 元素是否还能读属性。窗口关掉或视图重建后，AXUIElement 仍是个非空引用，
/// 但任何属性读取都会失败——只能靠实际读一次来判断死活。
func isAlive(_ el: AXUIElement) -> Bool {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &value)
    return err == .success && value != nil
}

/// 按结构路径重新定位元素：从应用根开始，逐段在子节点里找同 role 的第 N 个。
/// 这是失效重取的核心——模型手里的 elementID 跨越多次界面变化仍然可用。
func resolvePath(pid: pid_t, path: String) -> AXUIElement? {
    let root = AXUIElementCreateApplication(pid)
    var current: AXUIElement = root
    if let w = attr(root, kAXMainWindowAttribute as String),
       CFGetTypeID(w) == AXUIElementGetTypeID() {
        current = w as! AXUIElement
    }
    // 第一段对应根元素自身，跳过
    let segments = path.split(separator: "/").dropFirst()
    if segments.isEmpty { return current }

    for segment in segments {
        guard let open = segment.lastIndex(of: "["),
              let close = segment.lastIndex(of: "]"),
              close > open,
              let index = Int(segment[segment.index(after: open)..<close]) else { return nil }
        let role = String(segment[segment.startIndex..<open])
        var matched = 0
        var found: AXUIElement?
        for kid in childrenOf(current) {
            let kr = strAttr(kid, kAXRoleAttribute as String) ?? "AXUnknown"
            guard kr == role else { continue }
            if matched == index { found = kid; break }
            matched += 1
        }
        guard let next = found else { return nil }
        current = next
    }
    return current
}


/// 比较两行节点描述，列出真正变化的属性片段。
/// 逐空格切分后按 "key" 对齐，避免整行重读浪费 token。
func attributeDelta(from old: String, to new: String) -> String {
    let tokens: (String) -> [String] = { line in
        line.trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.hasPrefix("[") && !$0.isEmpty }
    }
    let a = tokens(old), b = tokens(new)
    if a == b { return "(结构位置变化)" }
    let setB = Set(b), setA = Set(a)
    let gone = a.filter { !setB.contains($0) }
    let came = b.filter { !setA.contains($0) }
    // 同 key 的值变化写成 key 旧→新，比「去掉 X / 改为 Y」短一半
    var pairs: [String] = []
    for g in gone.prefix(3) {
        if let eq = g.firstIndex(of: "=") {
            let key = String(g[g.startIndex..<eq])
            if let nv = came.first(where: { $0.hasPrefix(key + "=") }),
               let ne = nv.firstIndex(of: "=") {
                pairs.append(key + " " + String(g[g.index(after: eq)...]) + "→" + String(nv[nv.index(after: ne)...]))
                continue
            }
        }
        pairs.append("−" + g)
    }
    for c in came.prefix(3) {
        if let eq = c.firstIndex(of: "="),
           let key = Optional(String(c[c.startIndex..<eq])),
           gone.contains(where: { $0.hasPrefix(key + "=") }) { continue }
        if pairs.contains(where: { $0.hasPrefix(String(c[c.startIndex..<(c.firstIndex(of: "=") ?? c.endIndex)])) }) { continue }
        pairs.append("+" + c)
    }
    return pairs.isEmpty ? "(顺序变化)" : pairs.joined(separator: " ")
}

/// 把一串 ID 压成区间：100,101,102,105 → "100-102,105"
func compressRanges(_ ids: [Int]) -> String {
    let sorted = Array(Set(ids)).sorted()
    guard !sorted.isEmpty else { return "" }
    var parts: [String] = []
    var start = sorted[0]
    var prev = sorted[0]
    for v in sorted.dropFirst() {
        if v == prev + 1 { prev = v; continue }
        parts.append(start == prev ? String(start) : "\(start)-\(prev)")
        start = v
        prev = v
    }
    parts.append(start == prev ? String(start) : "\(start)-\(prev)")
    return parts.joined(separator: ",")
}


/// AX 元素所属窗口的 CGWindowID。
/// _AXUIElementGetWindow 是私有符号，但十几年未变，比「按 pid 猜面积最大的窗口」
/// 准确得多：同一个 app 开多个窗口时，猜法会把小窗指到主窗口上。
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 向上找 AXWindow 祖先并取它的窗口号。最多走 12 层，防止异常深的树拖时间。
func containingWindow(of el: AXUIElement) -> CGWindowID? {
    var cur = el
    for _ in 0..<12 {
        if let role = strAttr(cur, kAXRoleAttribute as String), role == "AXWindow" {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(cur, &wid) == .success, wid != 0 {
                return wid
            }
            return nil
        }
        guard let p = attr(cur, kAXParentAttribute as String),
              CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        cur = p as! AXUIElement
    }
    return nil
}

func element(pid: pid_t, id: Int) throws -> AXUIElement {
    guard let reg = registries[pid], let entry = reg[id] else {
        throw CUAError.staleElement("元素 [\(id)] 不在当前快照中，先调用 get_app_state 刷新")
    }
    if isAlive(entry.element) {
        return entry.element
    }
    // 引用失效：按指纹路径找回同一个控件，而不是逼模型重新取整棵树。
    if let fresh = resolvePath(pid: pid, path: entry.path) {
        let role = strAttr(fresh, kAXRoleAttribute as String) ?? entry.role
        // 只有 role 对得上才认：路径相撞时宁可不认，也不能点错控件
        if role == entry.role {
            registries[pid]?[id] = ElementEntry(
                element: fresh,
                path: entry.path,
                role: entry.role,
                title: entry.title
            )
            return fresh
        }
    }
    throw CUAError.staleElement(
        "元素 [\(id)] \(entry.role) \(entry.title) 已从界面消失，重取失败；请重新调用 get_app_state"
    )
}


// MARK: - 截图指纹
//
// 目的不是识别内容，而是判断「这一帧和上一帧是不是同一画面」。
// 8x8 灰度平均哈希足够：界面没动时哈希完全一致，动了必然不同。
// 用 JPEG 字节哈希会更敏感——同一画面重新编码也可能因量化差异变字节。

var lastShot: [pid_t: FrameSignature] = [:]

struct FrameSignature {
    let hash: UInt64
    /// 8×8 灰度的标准差。纯色画面接近 0，正常界面在几十。
    let spread: Double
}

func imageFingerprint(_ img: CGImage) -> FrameSignature {
    let w = 8, h = 8
    var buf = [UInt8](repeating: 0, count: w * h)
    let ok = buf.withUnsafeMutableBytes { raw -> Bool in
        guard let ctx = CGContext(
            data: raw.baseAddress,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return FrameSignature(hash: 0, spread: 0) }
    let total = buf.reduce(UInt64(0)) { $0 + UInt64($1) }
    let mean = Double(total) / Double(buf.count)
    var hash: UInt64 = 0
    for (i, v) in buf.enumerated() where Double(v) >= mean {
        hash |= (UInt64(1) << UInt64(i))
    }
    var acc = 0.0
    for v in buf {
        let d = Double(v) - mean
        acc += d * d
    }
    return FrameSignature(hash: hash, spread: (acc / Double(buf.count)).squareRoot())
}

func hamming(_ a: UInt64, _ b: UInt64) -> Int {
    (a ^ b).nonzeroBitCount
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

/// 截图并同时返回画面指纹，供调用方判断要不要真的把图发出去。
func captureWindowFrame(pid: pid_t, windowID: CGWindowID, maxDim: Int, quality: Double) throws -> (data: Data, sig: FrameSignature) {
    let sem = DispatchSemaphore(value: 0)
    var out: (Data, FrameSignature)?
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
            if let data = encodeJPEG(img, quality: quality) {
                out = (data, imageFingerprint(img))
            }
        } catch {
            failure = error
        }
        sem.signal()
    }
    _ = sem.wait(timeout: .now() + 30)
    if let o = out { return o }
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

// MARK: - 实时画面（cua-live）
//
// 对话页角标小窗的数据源。cua-live 常驻，以 3fps 抓目标窗口并输出 MJPEG；
// 这里只负责两件事：进程在不在、当前目标是谁。
// 用固定端口 18901 而非走宿主 webServer：跨端口的 <img> 不受 CORS 约束，
// 也就绕开了宿主那层登录中间件。

enum Live {
    static let port = 18901
    static var launched = false
    /// 抓帧是 3fps 的常驻开销，目标没变就不必重复通知
    static var lastKey = ""
    static var lastSentAt: Date = .distantPast

    static var binaryPath: String {
        let exe = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: "/tmp")
        return exe.appendingPathComponent("cua-live").path
    }

    static func url(_ path: String) -> URL? {
        URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    /// 端口上是否已经有人应答。用同步请求，超时压到 200ms。
    static func isServing() -> Bool {
        guard let u = url("/status") else { return false }
        var req = URLRequest(url: u)
        req.timeoutInterval = 0.2
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 { ok = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 0.4)
        return ok
    }

    static func ensureRunning() {
        if isServing() { return }
        if launched { return }
        launched = true
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binaryPath)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        for _ in 0..<40 {
            if isServing() { return }
            usleep(25_000)
        }
    }

    /// 告知 cua-live 当前操作目标。fire-and-forget，不阻塞工具调用。
    static func notify(pid: pid_t, appName: String, ttl: Double, windowID: CGWindowID? = nil) {
        let key = "\(pid)|\(appName)|\(windowID.map(String.init) ?? "-")"
        let now = Date()
        if key == lastKey, now.timeIntervalSince(lastSentAt) < 2.0 { return }
        lastKey = key
        lastSentAt = now
        ensureRunning()
        // 只用 urlQueryAllowed 会把 & 和 = 留在里面，应用名含这些字符时查询串会被截断
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        guard let encoded = appName.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
        var query = "/target?pid=\(pid)&ttl=\(Int(ttl))&app=\(encoded)"
        if let w = windowID { query += "&window=\(w)" }
        guard let u = url(query) else { return }
        // 同步等应答：cua-mcp 是一次性进程，fire-and-forget 的 task 会在退出时被丢弃，
        // 表现就是目标从未送达（2026-10-27 踩过）。这里 0.6 秒封顶，且已按 pid+app 节流。
        var req = URLRequest(url: u)
        req.timeoutInterval = 0.6
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 0.8)
    }
}

enum Overlay {
    static let socketPath = "/tmp/cua-overlay.sock"
    static var launched = false
    static var lastPID: pid_t = 0
    static var lastWindow: CGWindowID = 0
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
    static func mark(pid: pid_t, appName: String, windowID explicitWindow: CGWindowID? = nil) {
        guard CuaConfig.current().overlayEnabled else { return }
        // overlay 指令是 socket 往返 + 一次 CGWindowList 全量遍历，
        // 单次约 5-15ms。同一个 app 连续操作时没必要重发。
        // 只在切换目标或距上次发送超过 2s 时才刷新（保证 ttl 续期）。
        let now = Date()
        guard let wid = explicitWindow ?? windowID(for: pid) else { return }
        // 窗口号也参与节流判断：同一 app 换了窗口就得重新标记，
        // 否则小窗会一直停在上一个窗口上。
        if lastPID == pid, lastWindow == wid, now.timeIntervalSince(lastSentAt) < 2.0 { return }
        lastWindow = wid
        lastPID = pid
        lastSentAt = now

        // ttl 交给 overlay 自己计时。cua-mcp 是一次性进程，
        // 用本进程的 asyncAfter 收尾在进程退出后会失效，标记会永久残留。
        let ttl = CuaConfig.current().overlayTtlSeconds
        send([
            "cmd": "show",
            "windowID": Int(wid),
            "pid": Int(pid),
            "label": "AI 正在操作 \(appName)",
            "ttl": ttl,
        ])
        // 同步把目标交给实时画面服务，对话页角标小窗据此出图
        Live.notify(pid: pid, appName: appName, ttl: ttl, windowID: wid)
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

    // 主窗口标记为主窗口。窗口级 AXMain 只是让窗口自认为主窗口，
    // 不会把它提到用户面前。
    if let w = attr(appEl, kAXMainWindowAttribute as String),
       CFGetTypeID(w) == AXUIElementGetTypeID() {
        let win = w as! AXUIElement
        _ = setAttr(win, kAXMainAttribute as String, kCFBooleanTrue)
    }

    // 关键：只置应用级 AXFrontmost，不置应用级 AXFocused。
    // AXFocused 会真的把应用激活、窗口升起，把用户的焦点抢走；
    // AXFrontmost 让应用「自认为」前台而系统前台不变（2026-10-27 实测）。
    // 这正是 Codex syntheticallyActivateIfNeeded 的效果。
    _ = syntheticallyActivate(pid: pid)
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


// MARK: - 锁屏

/// 屏幕是否处于锁定状态。
/// 锁屏时 AX 读取和 CGEvent 投递都会被系统挡掉，逐个工具报错会让模型误判成
/// 「元素找不到」而反复重试；这里统一给出可读的原因。
func isScreenLocked() -> Bool {
    guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
}


// MARK: - 按应用提示

/// 可选的按应用提示。放在 `~/.dsh/dsh-cua-instructions/<bundleID>.md`，
/// 内容会插在快照头部，让模型取树之前先看到这个应用的坑。
/// 用文件而非内置表：应用差异得靠用的人补，硬编码永远追不上。
func appInstruction(bundleID: String) -> String? {
    guard !bundleID.isEmpty else { return nil }
    let path = NSHomeDirectory() + "/.dsh/dsh-cua-instructions/" + bundleID + ".md"
    guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}


// MARK: - 锁屏解锁
//
// 锁屏时 loginwindow 接管，postToPid 定向投递无效——它只认真实 HID 事件。
// 流程：唤醒屏幕 → 全局注入密码 → 回车 → 复查锁屏状态。
// 密码只作为本次调用参数，不落盘。

import IOKit.pwr_mgt

func wakeScreen() {
    var assertionID: IOPMAssertionID = 0
    _ = IOPMAssertionDeclareUserActivity(
        "dsh-cua unlock" as CFString,
        kIOPMUserActiveLocal,
        &assertionID
    )
}

/// 全局注入文本（HID tap 而非 postToPid）。锁屏界面用这个。
func typeTextHID(_ text: String) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    let units = Array(text.utf16)
    var i = 0
    while i < units.count {
        let chunk = Array(units[i..<min(i + 16, units.count)])
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { return }
        chunk.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress!)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        i += chunk.count
        usleep(6_000)
    }
}

/// 单个按键的全局注入。Return 用 keyCode 36。
func postKeyHID(_ keyCode: CGKeyCode) {
    guard let src = CGEventSource(stateID: .hidSystemState) else { return }
    CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(20_000)
    CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
}

func toolUnlockScreen(_ args: [String: Any]) throws -> [[String: Any]] {
    let password = (args["password"] as? String) ?? ""
    if !isScreenLocked() {
        return [["type": "text", "text": "屏幕已解锁，无需操作"]]
    }
    // 不唤醒的话注入落在黑屏上，等于没输
    wakeScreen()
    usleep(900_000)
    if password.isEmpty {
        return [["type": "text", "text": "已唤醒屏幕，但未提供密码，等待人工解锁"]]
    }
    typeTextHID(password)
    usleep(300_000)
    postKeyHID(36)   // return
    usleep(1_200_000)
    if isScreenLocked() {
        return [["type": "text", "text": "已尝试注入密码但屏幕仍处于锁定状态。请确认密码是否正确，或手动解锁。"]]
    }
    return [["type": "text", "text": "屏幕已解锁"]]
}


// MARK: - 合成激活
//
// Codex 的 syntheticallyActivateIfNeeded：让目标应用「自认为」在前台，
// 从而接受定向事件，但不把它的窗口提到用户面前。
//
// 实测（2026-10-27）：对应用元素设置 AXFrontmost=true 之后，
// 该应用的 AXFrontmost 读回 true，而 NSWorkspace.frontmostApplication
// 仍是原来的应用——正是需要的行为。用公开 AX API，无需私有符号。

func appIsFrontmost(pid: pid_t) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    return boolAttr(app, kAXFrontmostAttribute as String) == true
}

/// 让目标自认为前台。返回是否达成。
func syntheticallyActivate(pid: pid_t, timeout: TimeInterval = 0.5) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    if boolAttr(app, kAXFrontmostAttribute as String) == true { return true }
    let err = AXUIElementSetAttributeValue(
        app, kAXFrontmostAttribute as CFString, kCFBooleanTrue
    )
    guard err == .success else { return false }
    // Codex 的 waitUntilAppBelievesItIsFrontmost：置位不保证立刻生效，轮询确认
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if boolAttr(app, kAXFrontmostAttribute as String) == true { return true }
        usleep(20_000)
    }
    return false
}


/// 等目标应用有主窗口再动手。
/// Codex 的 waitUntilHasPrimaryWindow(timeout:pollingInterval:)：冷启动或
/// 窗口刚创建时 AX 树可能还没有窗口，此时点坐标会落到别处。
func waitForPrimaryWindow(pid: pid_t, timeout: TimeInterval = 1.5) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let w = attr(app, kAXMainWindowAttribute as String),
           CFGetTypeID(w) == AXUIElementGetTypeID() {
            return true
        }
        // 没有 AXMainWindow 的辅助应用，退一步看 AXWindows 是否非空
        if let list = attr(app, kAXWindowsAttribute as String) as? [AXUIElement], !list.isEmpty {
            return true
        }
        usleep(50_000)
    }
    return false
}

/// 动作前的统一前置：按配置决定是否合成激活。
func prepareTarget(pid: pid_t) {
    // 没有主窗口时先等，避免对着还没建好的界面操作
    _ = waitForPrimaryWindow(pid: pid)
    guard CuaConfig.current().syntheticActivate else { return }
    guard !appIsFrontmost(pid: pid) else { return }
    _ = syntheticallyActivate(pid: pid)
}

func toolGetAppState(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)

    // diff 默认 auto：有基线就只报变化，没基线（首次）自动退化成全量
    let diffMode = (args["diff"] as? String) ?? "auto"
    let snap = captureTree(pid: ref.pid, appName: ref.name, diffMode: diffMode)

    var treeText = snap.text
    if let tip = appInstruction(bundleID: ref.bundleID) {
        // 插在 App 行之后：模型读节点前先看到这个应用的注意事项
        var lines = treeText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        if lines.count == 2 {
            treeText = String(lines[0]) + "\n[应用提示] " + tip + "\n" + String(lines[1])
        } else {
            treeText = "[应用提示] " + tip + "\n" + treeText
        }
    }
    var content: [[String: Any]] = [["type": "text", "text": treeText]]

    // screenshot 默认 auto：画面与上次同尺寸且采样指纹一致就不附图。
    // 图片按尺寸占 token，长会话里「界面没动也重发一张」是主要浪费。
    let shotMode = (args["screenshot"] as? String) ?? "auto"
    let wantShot: Bool
    if shotMode == "true" || shotMode == "always" { wantShot = true }
    else if shotMode == "false" || shotMode == "never" { wantShot = false }
    else if let bool = args["screenshot"] as? Bool { wantShot = bool }
    else { wantShot = true }

    if wantShot {
        let maxDim = (args["max_dimension"] as? Int) ?? 1600
        let quality = (args["quality"] as? Double) ?? 0.6
        if let wid = windowID(for: ref.pid),
           let shot = try? captureWindowFrame(pid: ref.pid, windowID: wid, maxDim: maxDim, quality: quality) {
            let previous = lastShot[ref.pid]
            // 信息量判据（Codex 用 SkyshotClassifier，这里用可判定的信号替代）：
            //   1. 近乎纯色 → 这张图没有可读内容
            //   2. 与上帧逐位相同 → 没有任何变化
            //   3. 与上帧仅差 1-2 位且树几乎没动 → 变化不值得一张图
            let treeMoved = snap.changed + snap.added + snap.removed
            var skipReason: String?
            if shotMode == "auto" {
                if shot.sig.spread < 2.0 {
                    skipReason = "[画面近乎纯色，无有效信息，未附图]"
                } else if let p = previous {
                    let dist = hamming(p.hash, shot.sig.hash)
                    if dist == 0 {
                        skipReason = "[画面与上次一致，未重复附图；需要强制取图请传 screenshot=\"always\"]"
                    } else if dist <= 2, treeMoved <= 2 {
                        skipReason = "[画面与上帧仅有细微差异（汉明距离 \(dist)，树变化 \(treeMoved) 处），未附图]"
                    }
                }
            }
            if let reason = skipReason {
                content.append(["type": "text", "text": reason])
            } else {
                lastShot[ref.pid] = shot.sig
                content.append([
                    "type": "image",
                    "data": shot.data.base64EncodedString(),
                    "mimeType": "image/jpeg",
                ])
            }
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

    // 目标若不认为自己在前台，先合成激活（不抢用户焦点）
    prepareTarget(pid: ref.pid)

    // 若按元素点击，先让该元素成为 AXFocused —— 后台场景下这是让应用接受输入的关键。
    if let id = args["element_index"] as? Int {
        let el = try element(pid: ref.pid, id: id)
        // 元素属于哪个窗口就标记哪个：同一个 app 开多窗时，
        // 按「面积最大的窗口」猜会把小窗指错地方。
        if let w = containingWindow(of: el) {
            Overlay.mark(pid: ref.pid, appName: ref.name, windowID: w)
        }
        // 优先走 AXPress：鼠标事件即使定向投递到 pid，被点的应用也会
        // 当成真实点击、自己把窗口激活上来，用户焦点照样被抢。
        // AXPress 是纯 AX 动作，不经过事件系统，窗口不会被升起。
        if actionNames(of: el).contains(kAXPressAction as String),
           AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            // 光标要跟到元素位置：AXPress 不经过事件系统，
            // 若不主动移动，屏幕上看到的是「AI 说点了但光标没动」。
            if let c = elementCenter(el) {
                Overlay.cursorClick(x: c.x, y: c.y)
            }
            waitForChange(pid: ref.pid)
            return [["type": "text", "text": "已对 \(ref.name) 的元素 [\(id)] 执行 AXPress"]]
        }
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
    prepareTarget(pid: ref.pid)
    try typeText(pid: ref.pid, text: text)
    waitForChange(pid: ref.pid)
    return [["type": "text", "text": "已向 \(ref.name) 输入 \(text.count) 个字符"]]
}

func toolPressKey(_ args: [String: Any]) throws -> [[String: Any]] {
    guard let q = args["app"] as? String else { throw CUAError.badRequest("app 必填") }
    guard let key = args["key"] as? String else { throw CUAError.badRequest("key 必填") }
    let ref = try resolveApp(q)
    Overlay.mark(pid: ref.pid, appName: ref.name)
    prepareTarget(pid: ref.pid)
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

    let available = actionNames(of: el)
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
    ToolDef(name: "screen_state", description: "返回 locked 或 unlocked。锁屏时其它工具都会失败。",
            schema: obj([:], [])),
    ToolDef(name: "unlock_screen",
            description: "唤醒屏幕并注入密码解锁。密码只用于本次调用，不落盘。不传密码则只唤醒。",
            schema: obj([
                "password": ["type": "string", "description": "登录密码；省略则只唤醒屏幕等待人工解锁"],
            ], [])),
    ToolDef(name: "get_app_state",
            description: "获取应用的辅助功能树文本，以及一张截图。返回的 [数字] 是元素 ID，供后续动作使用。元素 ID 跨快照稳定，界面变化后仍可沿用。",
            schema: obj([
                "app": appP,
                "diff": ["type": "string", "enum": ["auto", "cumulative", "none"],
                         "description": "auto（默认）：只返回相对上一轮的变化，未变的沿用上轮 ID；cumulative：相对最初那棵树；none：完整树"],
                "screenshot": ["type": "string", "enum": ["auto", "always", "never"],
                         "description": "auto（默认）：画面与上次一致时不重复附图；always/never 强制"],
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
        // 锁屏时所有依赖 AX / 截屏 / 注入的工具都会失败，先给准确原因
        if isScreenLocked(), name != "list_apps", name != "screen_state", name != "unlock_screen" {
            throw CUAError.badRequest("屏幕已锁定（loginwindow 接管）。AX 读取、截屏与输入投递都不可用，可用 unlock_screen 唤醒解锁。")
        }
        // 应用策略：带 app 参数的工具在落到目标之前先过白/黑名单
        if let appQuery = args["app"] as? String, let target = try? resolveApp(appQuery),
           let reason = policyDecision(for: target) {
            throw CUAError.badRequest(reason)
        }
        let content: [[String: Any]]
        switch name {
        case "list_apps": content = try toolListApps(args)
        case "screen_state": content = [[
            "type": "text",
            "text": isScreenLocked() ? "locked" : "unlocked",
        ]]
        case "unlock_screen": content = try toolUnlockScreen(args)
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

        // 路径指纹自检：用 path 重新解析，必须解回同一个 AX 元素。
        // 重取逻辑全部依赖这一步，错了的话「元素失效自动找回」就是空话。
        let reg = registries[first.processIdentifier] ?? [:]
        var hit = 0, miss = 0
        var samples: [(Int, ElementEntry)] = []
        for (id, entry) in reg { samples.append((id, entry)) }
        samples.sort { $0.0 < $1.0 }
        for (_, entry) in samples.prefix(60) {
            if let back = resolvePath(pid: first.processIdentifier, path: entry.path),
               CFEqual(back, entry.element) {
                hit += 1
            } else {
                miss += 1
            }
        }
        print("path resolve: hit=\(hit) miss=\(miss)")
        // ID 区间压缩自检：连续段合并，孤立项单列
        print("range compress:", compressRanges([100, 101, 102, 105, 107, 108, 109]))
    }

    let cfg = CuaConfig.current()
    print("config path:", CuaConfig.path)
    print("config readable:", FileManager.default.isReadableFile(atPath: CuaConfig.path))
    print("config policy: denied=\(cfg.deniedBundleIDs.count) allowed=\(cfg.allowedBundleIDs.count)")
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

// MARK: - 事件循环
//
// 原来用 `while let line = readLine()` 阻塞读 stdin。那样主线程永远卡在 read 上，
// AXObserver 的通知（需要 RunLoop 送达）永远收不到。
// 改成 DispatchSourceRead 监听 fd 0、主线程跑 RunLoop：
// 既能处理请求，又能接收元素销毁/窗口变化通知。

/// 把一行 JSON-RPC 处理完。所有 AX/AppKit 操作都在主线程，避免线程问题。
func handleLine(_ line: String) {
    if line.isEmpty { return }
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        send(errorResponse(nil, -32700, "JSON 解析失败"))
        return
    }

    let id = msg["id"]
    guard let method = msg["method"] as? String else {
        if id != nil { send(errorResponse(id, -32600, "缺少 method")) }
        return
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

var stdinBuffer = Data()

let stdinSource = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
stdinSource.setEventHandler {
    var chunk = [UInt8](repeating: 0, count: 65536)
    let n = read(0, &chunk, chunk.count)
    guard n > 0 else {
        // stdin 关闭：父进程走了，正常收尾
        stdinSource.cancel()
        exit(0)
    }
    stdinBuffer.append(contentsOf: chunk[0..<n])
    while let nl = stdinBuffer.firstIndex(of: 0x0A) {
        let lineData = stdinBuffer[stdinBuffer.startIndex..<nl]
        stdinBuffer.removeSubrange(stdinBuffer.startIndex...nl)
        guard let text = String(data: lineData, encoding: .utf8) else { continue }
        handleLine(text)
    }
}
stdinSource.resume()

RunLoop.main.run()
