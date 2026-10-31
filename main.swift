import AppKit
import Foundation

// MARK: - 数据模型

struct AppEntry: Identifiable {
    let id: String          // bundle 路径
    let path: String
    let name: String
    let slotName: String    // 槽位目录名（用 CFBundleName，保证与既有槽位兼容，如 Qianwen2）
    let bundleID: String?
    let executable: String?
    let isChromium: Bool
}

// MARK: - 多开引擎（GUI 与 CLI 共用）

final class LauncherEngine {
    static let shared = LauncherEngine()
    private var pendingSlots: [String: Date] = [:]   // 槽位路径 -> 过期时间
    private let lock = NSLock()

    // MARK: 应用列表

    func listApps() -> [AppEntry] {
        // 实时扫描（每次启动/点刷新都重新读目录，没有任何缓存名单）
        // 覆盖：用户应用 + 系统应用（含 Utilities）；CoreServices 里是 Finder/Dock 等系统进程，跳过
        let bases = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
            "/System/Applications",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications",
        ]
        var paths: [String] = []
        let fm = FileManager.default
        for base in bases {
            for dir in [base, base + "/Utilities"] {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for item in items.sorted() where item.hasSuffix(".app") {
                    paths.append(dir + "/" + item)
                }
            }
        }
        let selfPath = Bundle.main.bundlePath
        var seenBundles = Set<String>()
        var result: [AppEntry] = []
        for p in paths {
            guard p != selfPath, let e = makeEntry(path: p) else { continue }
            // 按 bundleID 去重（例如 /Applications 的 Safari 桩与 cryptex 真身同 ID，保留先扫到的）
            let key = e.bundleID ?? e.path
            if seenBundles.insert(key).inserted { result.append(e) }
        }
        return result
    }

    func makeEntry(path: String) -> AppEntry? {
        // 直接读原始 Info.plist（NSDictionary）取槽位名，避免 Bundle API 返回本地化后的名字
        // （例如千问 zh_CN 本地化把 CFBundleName 覆盖为"千问"，会导致槽位目录名不稳定）；
        // 显示名则用 Bundle API 取本地化名字，界面更友好
        guard let raw = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              let exeName = raw["CFBundleExecutable"] as? String else { return nil }
        let exe = path + "/Contents/MacOS/" + exeName
        guard FileManager.default.fileExists(atPath: exe) else { return nil }
        let rawName = (raw["CFBundleDisplayName"] as? String)
            ?? (raw["CFBundleName"] as? String)
            ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let localName = Bundle(path: path)?
            .object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? rawName
        let bundleName = (raw["CFBundleName"] as? String) ?? ""
        let slotName = sanitized(bundleName.isEmpty ? rawName : bundleName)
        return AppEntry(id: path, path: path, name: localName, slotName: slotName,
                        bundleID: raw["CFBundleIdentifier"] as? String,
                        executable: exe, isChromium: detectChromium(path))
    }

    private func detectChromium(_ path: String) -> Bool {
        let fw = path + "/Contents/Frameworks"
        guard let subs = try? FileManager.default.subpathsOfDirectory(atPath: fw) else { return false }
        return subs.contains { s in
            s.contains("chrome_crashpad_handler")
                || s.contains("Electron Framework")
                || s.contains("Chromium Embedded")
        }
    }

    // MARK: 进程查询

    func psLines() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["ax", "-o", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        // 注意：必须在 waitUntilExit 之前读完管道，否则 ps 输出超过管道缓冲区时会死锁
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.components(separatedBy: "\n") ?? []
    }

    func isMainLine(_ line: String, exe: String) -> Bool {
        line == exe || line.hasPrefix(exe + " ")
    }

    func runningCounts(for apps: [AppEntry]) -> [String: Int] {
        var result: [String: Int] = [:]
        for app in apps {
            result[app.id] = runningInstanceCount(app)
        }
        return result
    }

    /// 按 Bundle ID 统计运行实例数（NSRunningApplication）。
    /// 不能按可执行文件路径匹配：macOS 26 的 Safari 等应用是 cryptex 桩，
    /// 真实进程跑在 /System/Volumes/Preboot/Cryptexes/… 路径下。
    func runningInstanceCount(_ app: AppEntry) -> Int {
        if let bid = app.bundleID {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bid).count
        }
        guard let exe = app.executable else { return 0 }
        return psLines().filter { isMainLine($0, exe: exe) }.count
    }

    // MARK: 启动

    /// 结果：(是否成功, 给用户看的消息)
    func launch(app: AppEntry) -> (ok: Bool, message: String) {
        guard app.executable != nil else {
            return (false, "无法读取 “\(app.name)” 的可执行文件")
        }
        let count0 = runningInstanceCount(app)

        // 没有任何实例在运行：正常启动第一个即可
        if count0 == 0 {
            runOpen([app.path])
            if waitFor(timeout: 8, condition: { [weak self] in
                self?.runningInstanceCount(app) ?? 0 > 0
            }) {
                return (true, "已启动 “\(app.name)”（首个实例）")
            }
            return (false, "启动 “\(app.name)” 失败")
        }

        let ordinal = count0 + 1

        // Chromium/Electron 系：独立数据目录槽位
        if app.isChromium, let exe = app.executable {
            var lastSlot: String? = nil
            for _ in 0..<3 {
                // 每次尝试都重新选择基目录：沙盒应用只用其容器内目录（外部目录写不进去，
                // 会产生无法持久化的坏实例）；应用从未运行过时容器可能刚被 LaunchServices 创建
                let base = pickSlotBase(app)
                // 失败后重试同一槽位：open -n 偶发静默失败时换槽位反而会开重复窗口
                let slot = lastSlot ?? nextFreeSlot(base: base ?? "", appName: app.slotName)
                guard let slot else { break }
                markPending(slot)
                runOpen(["-n", app.path, "--args", "--user-data-dir=" + slot])
                if waitFor(timeout: 8, condition: { [weak self] in
                    guard let self else { return false }
                    return self.psLines().contains { line in
                        self.isMainLine(line, exe: exe)
                            && (line.hasSuffix(slot) || line.contains(slot + " "))
                    }
                }) {
                    return (true, "已新开 “\(app.name)” 窗口（第 \(ordinal) 个实例）")
                }
                lastSlot = slot
            }
            return (false, "“\(app.name)” 的新实例启动后未能存活，可能不支持这种多开方式")
        }

        // 普通应用：open -n 新实例 + 实例数验证
        runOpen(["-n", app.path])
        if waitFor(timeout: 8, condition: { [weak self] in
            (self?.runningInstanceCount(app) ?? 0) > count0
        }) {
            return (true, "已新开 “\(app.name)” 窗口（第 \(ordinal) 个实例）")
        }
        return (false, "“\(app.name)” 自带单实例限制，暂不支持多开")
    }

    // MARK: 槽位管理

    /// 当前应使用的槽位根目录：容器存在则用容器内（沙盒应用唯一可写位置，
    /// 兼容千问既有槽位 Qianwen2…），否则用外部公共目录（非沙盒 Chromium 应用支持任意路径）
    private func pickSlotBase(_ app: AppEntry) -> String? {
        let home = NSHomeDirectory()
        if let bid = app.bundleID {
            let cont = home + "/Library/Containers/\(bid)/Data/Library/Application Support"
            if FileManager.default.fileExists(atPath: cont) { return cont }
        }
        return home + "/Library/Application Support/MultiOpener/\(app.bundleID ?? app.slotName)"
    }

    /// 找空闲槽位：编号从 2 起（<SlotName>N），跳过运行中/待启动占用的编号
    private func nextFreeSlot(base: String, appName: String) -> String? {
        let lines = psLines()
        for n in 2...50 {
            let slot = "\(base)/\(appName)\(n)"
            let inUse = lines.contains { line in
                line.hasSuffix(slot) || line.contains(slot + " ")
            }
            let pending = isPending(slot)
            if !inUse && !pending { return slot }
        }
        return nil
    }

    private func markPending(_ slot: String) {
        lock.lock(); defer { lock.unlock() }
        pendingSlots[slot] = Date().addingTimeInterval(20)
    }

    private func isPending(_ slot: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let expiry = pendingSlots[slot], expiry > Date() { return true }
        pendingSlots.removeValue(forKey: slot)
        return false
    }

    /// 目录名净化的槽位名：字母/数字/CJK 保留，其余删除（Qianwen → Qianwen2 保持兼容）
    private func sanitized(_ s: String) -> String {
        let filtered = s.unicodeScalars.filter { sc in
            CharacterSet.alphanumerics.contains(sc) || sc.value > 0x2E7F
        }
        let result = String(String.UnicodeScalarView(filtered))
        return result.isEmpty ? "App" : result
    }

    // MARK: 工具

    @discardableResult
    private func runOpen(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        // 清洗环境：如果本应用是从带 ELECTRON_RUN_AS_NODE 等变量的环境启动的
        // （例如由 Electron 宿主派生），open 会把这些变量传给被启动的应用，
        // 导致 Electron 类应用（如汽水音乐）被当作纯 Node 进程直接退出
        p.environment = Self.cleanEnvironment
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 }
        catch { return false }
    }

    /// 剥离 Electron/Node 注入的环境变量后的干净环境
    static let cleanEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("ELECTRON")
                                || key.hasPrefix("NODE_")
                                || key.hasPrefix("npm_")
                                || key == "V8_OPTIONS" {
            env.removeValue(forKey: key)
        }
        return env
    }()

    private func waitFor(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            if condition() { return true }
        }
        // 宽限复查：冷启动偶发超过验证窗口，再给 3 秒做最后确认，避免误判后重复开
        Thread.sleep(forTimeInterval: 3)
        return condition()
    }
}

// MARK: - 主界面（纯 AppKit）

// MARK: - 应用卡片视图

/// 单个应用卡片：圆角矩形 + 应用图标 + 名称 + 运行数角标，整卡可点
final class AppCardView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "1")
    private var trackingArea: NSTrackingArea?
    private var hovered = false

    /// 图标缓存（线程安全：列表加载时可在后台队列预取，避免主线程卡顿）
    private static let iconLock = NSLock()
    private static var iconCache: [String: NSImage] = [:]

    static func iconImage(for path: String) -> NSImage {
        iconLock.lock()
        if let cached = iconCache[path] { iconLock.unlock(); return cached }
        iconLock.unlock()
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 64, height: 64)
        iconLock.lock()
        iconCache[path] = icon
        iconLock.unlock()
        return icon
    }

    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemGreen.cgColor
        badge.layer?.cornerRadius = 10
        badge.layer?.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badge)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 56),
            iconView.heightAnchor.constraint(equalToConstant: 56),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badge.widthAnchor.constraint(equalToConstant: 20),
            badge.heightAnchor.constraint(equalToConstant: 20),
            badge.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -2),
            badge.centerYAnchor.constraint(equalTo: iconView.topAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func configure(app: AppEntry, count: Int) {
        iconView.image = AppCardView.iconImage(for: app.path)
        nameLabel.stringValue = app.name
        toolTip = "\(app.name)\n\(app.path)"
        updateCount(count)
    }

    func updateCount(_ n: Int) {
        badge.isHidden = n <= 0
        badge.stringValue = n > 9 ? "9+" : "\(n)"
    }

    // 外观：无边框无底色（Launchpad 风格），仅悬停时显示圆角高亮
    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        path.fill()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                owner: self, userInfo: nil)
        trackingArea = ta
        addTrackingArea(ta)
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    /// 整张卡片可点：命中图标/文字/角标的点击都路由到卡片自身，
    /// 避免子视图吞掉鼠标事件（NSTextField/NSImageView 可能不向 responder chain 转发）
    override func hitTest(_ point: NSPoint) -> NSView? {
        return super.hitTest(point) == nil ? nil : self
    }

    // 无障碍支持：让整卡成为可按压的按钮（辅助功能 + 自动化测试都能触发）
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { nameLabel.stringValue }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - 主界面（网格布局）

/// 顶部优先的垂直容器：NSStackView 默认非翻转（y=0 在底部），
/// 会导致内容少的场景（如搜索结果）沉到窗口底部、首行排在最下面。
/// 翻转后 y=0 在顶部——与 NSTableView 等一致。
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

final class ListController: NSViewController {
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "点击应用卡片即可多开；未运行的应用会正常启动")
    private let refreshButton = NSButton()
    private let scrollView = NSScrollView()
    private var grid = FlippedStackView()

    /// 卡片尺寸参数（列数随窗口宽度自适应，见 columnsForWidth）
    private let cardHeight: CGFloat = 104
    private let targetCardWidth: CGFloat = 104
    private let cardGap: CGFloat = 10
    private let gridInset: CGFloat = 14
    private var currentColumns = 0
    private var reflowObserver: NSObjectProtocol?

    private var apps: [AppEntry] = []
    private var counts: [String: Int] = [:]
    /// 正在启动的应用（按应用隔离，不再全局锁死——否则一个应用启动失败重试的十几秒里，点其他应用会被静默吞掉）
    private var launchingApps: Set<String> = []
    private var timer: Timer?
    private var cards: [AppCardView] = []
    private var cardsApps: [AppEntry] = []

    private var displayApps: [AppEntry] {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return base.sorted { a, b in
            let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
            if (ca > 0) != (cb > 0) { return ca > 0 }
            return a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    override func loadView() {
        let w: CGFloat = 540, h: CGFloat = 680
        view = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // 液态玻璃背景：透出窗口后面的桌面内容（配合透明标题栏）
        let glass = NSVisualEffectView(frame: view.bounds)
        glass.material = .underWindowBackground
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        view.addSubview(glass)

        // 顶部搜索（加大：32pt 高 + 大字号）
        searchField.placeholderString = "搜索应用"
        searchField.font = .systemFont(ofSize: 14)
        searchField.controlSize = .large
        searchField.frame = NSRect(x: 14, y: h - 36 - 32, width: w - 28, height: 32)
        searchField.autoresizingMask = [.minYMargin, .width]
        searchField.delegate = self
        view.addSubview(searchField)

        // 中部网格（可滚动）
        let gridTop: CGFloat = 36 + 32 + 10   // 标题栏高度 + 搜索框 + 间距
        scrollView.frame = NSRect(x: 0, y: 40, width: w, height: h - 40 - gridTop)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        view.addSubview(scrollView)

        grid = FlippedStackView()
        grid.orientation = .vertical
        grid.spacing = 12
        grid.edgeInsets = NSEdgeInsets(top: 4, left: gridInset, bottom: 14, right: gridInset)
        grid.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = grid
        // 锚定到滚动视图的内容区：顶部固定 + 宽度跟随（列数自适应），
        // 高度由内容行数决定（可滚动）。配合翻转坐标系，
        // 搜索结果再少也贴顶显示。
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            grid.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            grid.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        // 视口宽度变化时自适应重排列数（滚动也会触发 bounds 变化，但只在列数变化时才重建）
        reflowObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
            queue: .main) { [weak self] _ in
            self?.reflowIfNeeded()
        }

        // 底部分隔线
        let divider = NSBox()
        divider.boxType = .separator
        divider.frame = NSRect(x: 0, y: 38, width: w, height: 2)
        divider.autoresizingMask = [.maxYMargin, .width]
        view.addSubview(divider)

        // 底部状态栏 + 刷新按钮
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 12, y: 10, width: w - 70, height: 20)
        statusLabel.autoresizingMask = [.maxYMargin, .width]
        view.addSubview(statusLabel)

        if let img = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新") {
            refreshButton.image = img
            refreshButton.imagePosition = .imageOnly
        } else {
            refreshButton.title = "刷新"
        }
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.frame = NSRect(x: w - 44, y: 6, width: 34, height: 28)
        refreshButton.autoresizingMask = [.minXMargin, .maxYMargin]
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked(_:))
        view.addSubview(refreshButton)

        // 定时刷新运行数（只更新角标，不重建网格）
        timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshCounts()
        }

        reloadApps()
    }

    deinit {
        if let o = reflowObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 数据加载

    private func reloadApps() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let list = LauncherEngine.shared.listApps()
            let cnts = LauncherEngine.shared.runningCounts(for: list)
            // 后台预取全部图标，避免首次构建网格时主线程卡顿
            for a in list { _ = AppCardView.iconImage(for: a.path) }
            DispatchQueue.main.async {
                self.apps = list
                self.counts = cnts
                if list.isEmpty {
                    self.statusLabel.stringValue = "未找到任何应用"
                } else if self.launchingApps.isEmpty {
                    self.statusLabel.stringValue = "共 \(list.count) 个应用 · 点击卡片即可多开"
                }
                self.rebuildGrid()
            }
        }
    }

    private func refreshCounts() {
        guard !apps.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let cnts = LauncherEngine.shared.runningCounts(for: self.apps)
            DispatchQueue.main.async {
                self.counts = cnts
                self.updateCards()
            }
        }
    }

    // MARK: 自适应列数

    /// 按视口宽度计算每行列数：目标卡宽 104 + 间距 10，卡片再由 fillEqually 拉伸铺满行宽
    private func columnsForWidth(_ w: CGFloat) -> Int {
        max(2, Int((w - gridInset * 2 + cardGap) / (targetCardWidth + cardGap)))
    }

    private func reflowIfNeeded() {
        let w = scrollView.contentView.bounds.width
        let cols = columnsForWidth(w)
        if cols != currentColumns {
            currentColumns = cols
            rebuildGrid()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        reflowIfNeeded()
    }

    // MARK: 网格构建

    private func rebuildGrid() {
        // 清空旧卡片
        for arranged in grid.arrangedSubviews {
            grid.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        cards.removeAll()
        cardsApps.removeAll()

        if currentColumns == 0 {
            currentColumns = columnsForWidth(scrollView.contentView.bounds.width)
        }
        let list = displayApps
        var rowViews: [NSStackView] = []
        var rowItems: [AppCardView] = []

        func flushRow() {
            guard !rowItems.isEmpty else { return }
            let row = NSStackView(views: rowItems)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = cardGap
            rowViews.append(row)
            rowItems.removeAll()
        }

        for app in list {
            let card = AppCardView(frame: .zero)
            card.configure(app: app, count: counts[app.id] ?? 0)
            card.onClick = { [weak self] in self?.launch(app) }
            card.heightAnchor.constraint(equalToConstant: cardHeight).isActive = true
            rowItems.append(card)
            cards.append(card)
            cardsApps.append(app)
            if rowItems.count == currentColumns { flushRow() }
        }
        flushRow()

        for row in rowViews {
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }

        if list.isEmpty, !searchField.stringValue.isEmpty {
            statusLabel.stringValue = "没有匹配 “\(searchField.stringValue)” 的应用"
        }
        // 滚回顶部（等布局完成后执行；兼容翻转/非翻转文档坐标系）
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let y = self.grid.isFlipped ? 0 : .greatestFiniteMagnitude
            self.scrollView.contentView.scroll(NSPoint(x: 0, y: y))
        }
    }

    private func updateCards() {
        for (card, app) in zip(cards, cardsApps) {
            card.updateCount(counts[app.id] ?? 0)
        }
    }

    // MARK: 行为

    @objc private func refreshClicked(_ sender: Any?) {
        reloadApps()
    }

    private func launch(_ app: AppEntry) {
        guard !launchingApps.contains(app.id) else { return }
        launchingApps.insert(app.id)
        statusLabel.stringValue = "正在为 “\(app.name)” 开新窗口…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let r = LauncherEngine.shared.launch(app: app)
            DispatchQueue.main.async {
                self.launchingApps.remove(app.id)
                self.statusLabel.stringValue = r.message
                self.refreshCounts()
                // 失败要弹窗明示（底部小字太不显眼，用户会以为多开功能坏了）
                if !r.ok {
                    let alert = NSAlert()
                    alert.messageText = "“\(app.name)”"
                    var info = r.message
                    if r.message.contains("启动") && r.message.contains("失败") {
                        info += "\n\n连正常启动都没成功（与多开无关），\n可先试着直接双击打开该应用确认它本身是否正常。"
                    }
                    alert.informativeText = info
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好")
                    if let w = self.view.window {
                        alert.beginSheetModal(for: w, completionHandler: nil)
                    }
                }
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildGrid()
    }
}

extension ListController: NSSearchFieldDelegate {}

// MARK: - 应用委托

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = ListController()
        let window = NSWindow(contentViewController: controller)
        window.title = "多开助手"
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 540, height: 680))
        window.minSize = NSSize(width: 470, height: 480)
        window.isRestorable = false   // 禁用状态恢复，避免历史错误尺寸被反复还原
        window.setFrameAutosaveName("MultiOpenerGridV2")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - 入口（main.swift）

let cliArgs = CommandLine.arguments

// CLI: --launch <app路径>
if let i = cliArgs.firstIndex(of: "--launch"), i + 1 < cliArgs.count {
    let path = cliArgs[i + 1]
    if let entry = LauncherEngine.shared.makeEntry(path: path) {
        let r = LauncherEngine.shared.launch(app: entry)
        print(r.ok ? "OK: \(r.message)" : "FAIL: \(r.message)")
        exit(r.ok ? 0 : 1)
    }
    print("FAIL: 无法识别应用 \(path)")
    exit(1)
}

// CLI: --count <app路径>
if let i = cliArgs.firstIndex(of: "--count"), i + 1 < cliArgs.count {
    let path = cliArgs[i + 1]
    if let entry = LauncherEngine.shared.makeEntry(path: path) {
        print("COUNT \(LauncherEngine.shared.runningInstanceCount(entry))")
        exit(0)
    }
    print("FAIL: 无法识别应用 \(path)")
    exit(1)
}

// CLI: --list
if cliArgs.contains("--list") {
    for a in LauncherEngine.shared.listApps() {
        print("\(a.name)\t\(a.isChromium ? "chromium" : "plain")\t\(a.path)")
    }
    exit(0)
}

// GUI
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
