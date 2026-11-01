import AppKit

final class PetView: NSView {
    enum State {
        case walking(dir: Int)
        case climbing(side: Int, up: Bool)
        case crawlingTop(dir: Int)
        case sitting
        case falling
        case dragged
        case pondering   // 走着走着停下，站着沉思
        case waving      // 停下打招呼（手绘12帧：蹲跳欢呼）
        case blushing    // 站定脸红（手绘8帧，走路时右键触发播一次）
        case idleBall    // 待机：绳拴屏幕顶边的球，在左上角甩圈（默认状态）
    }

    static let side: CGFloat = 120
    static let headR: CGFloat = 8
    /// 手绘贴图帧（放 Stickman.app/Contents/Resources/<动作>/01.png…）
    static let ponderFrames: [CGImage] = loadFrames("ponder")
    /// 手绘行走帧（素材朝右，walkDir==-1 镜像）。与 ponder 同一条 1/2 渲染管线，头径严格一致
    static let walkFrames: [CGImage] = loadFrames("walk")
    /// 手绘打招呼帧：12帧 8fps，画布 240×280（跳跃需要头部空间），头径与 walk 严格一致（37px）
    static let greetFrames: [CGImage] = loadFrames("greet")
    /// 手绘脸红帧：8帧 8fps，画布 240×240，头径与 walk 严格一致（37px），右键触发播一次
    static let blushFrames: [CGImage] = loadFrames("blush")
    /// 待机球帧：绳拴屏幕顶边、球甩圈。画布 240 → 1/3 绘制，球径 61px→20.3pt 与爬行一致
    static let idleFrames: [CGImage] = loadFrames("idle")
    /// 拖动 / 双击掉落时的球图标（同时是 App 图标）
    static let iconImage: CGImage? = {
        guard let u = Bundle.main.resourceURL?.appendingPathComponent("icon.png"),
              let img = NSImage(contentsOf: u) else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
    /// 图标绘制视口边长：图标球径 57px × 视口/240 = 爬行球径 61px × 1/3 → 80 × 61/57
    static let iconSide: CGFloat = 80 * 61.0 / 57.0
    /// 手绘贴边爬行帧：右侧例图（头在左、四条触须伸向画布右缘=屏幕边），左侧镜像播
    static let climbFrames: [CGImage] = loadFrames("climb")
    /// 贴图绘制缩放（用户定的 2/3），右对齐锚定屏幕边、垂直居中
    static let climbScale: CGFloat = 2.0 / 3.0
    /// 每帧头心（240 画布坐标、y 从顶算；climb_prep.py 实测导出，左侧镜像时 x 取反）
    static let climbHeadPts: [CGPoint] = [
        CGPoint(x: 171.5, y: 117), CGPoint(x: 171.5, y: 117), CGPoint(x: 171.5, y: 117),
        CGPoint(x: 171.5, y: 117), CGPoint(x: 171.5, y: 117), CGPoint(x: 171.5, y: 117),
        CGPoint(x: 171.5, y: 113), CGPoint(x: 171.5, y: 117), CGPoint(x: 171.5, y: 117),
        CGPoint(x: 171.5, y: 113),
    ]
    /// 手绘顶边攀行帧：双手扒屏幕顶边、身体垂下。画布 240×240，头径与 walk 严格一致（37px），
    /// 第一帧双手最高点=画布 y=0=屏幕顶边，各帧同一位置（无旋转、无上下移动）
    static let crawlTopFrames: [CGImage] = loadFrames("crawltop")
    /// 每帧头心（240 画布坐标、y 从顶算；dir==-1 镜像时 x 取反）
    static let crawlTopHeadPts: [CGPoint] = [
        CGPoint(x: 112.0, y: 32.6), CGPoint(x: 113.2, y: 45.1), CGPoint(x: 114.4, y: 54.7),
        CGPoint(x: 108.4, y: 58.3), CGPoint(x: 109.6, y: 44.0), CGPoint(x: 113.2, y: 51.1),
        CGPoint(x: 113.2, y: 53.5), CGPoint(x: 113.2, y: 55.9),
    ]
    /// 待机球每帧球心（视图坐标、y 向上；逐帧最大弦段测出）——hitTest 动态热区用
    static let idleBallPts: [CGPoint] = [
        CGPoint(x: 74.8, y: 79.3), CGPoint(x: 53.5, y: 96.3), CGPoint(x: 38.7, y: 93.7),
        CGPoint(x: 47.7, y: 110.3), CGPoint(x: 35.7, y: 93.0), CGPoint(x: 44.5, y: 83.7),
        CGPoint(x: 58.2, y: 99.3), CGPoint(x: 69.0, y: 102.7), CGPoint(x: 81.0, y: 93.7),
        CGPoint(x: 83.0, y: 119.3), CGPoint(x: 83.0, y: 92.3), CGPoint(x: 74.5, y: 100.3),
    ]
    /// 手绘坐姿帧：坐在宿主窗口顶边上摇头晃脚。画布 240×264 × 1/2 = 视口 120×132（窗口临时加高），
    /// 接触线（屁股+双手，画布 y=148）= 视图 y=58 = 宿主顶边（origin.y = 宿主顶-58）。头径与 walk 严格一致（37px）
    static let sitFrames: [CGImage] = loadFrames("sit")
    /// 每帧头心（视图坐标、相对窗口中心 (60,60)、y 向上；sit_lie_prep.py 逐帧模板匹配导出）
    static let sitHeadPts: [CGPoint] = [
        CGPoint(x: 1.5, y: 26.25), CGPoint(x: -1.55, y: 24.3), CGPoint(x: -5.15, y: 24.05),
        CGPoint(x: -5.15, y: 24.05), CGPoint(x: -1.25, y: 22.95), CGPoint(x: 1.5, y: 25.45),
        CGPoint(x: 5.35, y: 21.3), CGPoint(x: 10.35, y: 22.1), CGPoint(x: 10.35, y: 22.1),
        CGPoint(x: 5.35, y: 21.3),
    ]
    /// 手绘躺姿帧：躺在宿主窗口顶边上。画布 240×240 × 1/2 整窗，
    /// 身体直线（画布 y=148）= 视图 y=46 = 宿主顶边（origin.y = 宿主顶-46）。
    /// 素材头朝左固定不镜像；头左上方是睡觉泡泡（装饰，非头，勿混用）
    static let lieFrames: [CGImage] = loadFrames("lie")
    /// 每帧头心（视图坐标、相对窗口中心 (60,60)、y 向上；模板匹配时已排除泡泡连通域）
    static let lieHeadPts: [CGPoint] = [
        CGPoint(x: -20.15, y: -7.2), CGPoint(x: -23.0, y: -6.9), CGPoint(x: -20.15, y: -7.5),
        CGPoint(x: -20.45, y: -8.05), CGPoint(x: -21.0, y: -8.35), CGPoint(x: -21.3, y: -7.8),
        CGPoint(x: -21.9, y: -7.8), CGPoint(x: -23.0, y: -6.9),
    ]

    static func loadFrames(_ name: String) -> [CGImage] {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent(name),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [CGImage] = []
        for f in names.filter({ $0.lowercased().hasSuffix(".png") }).sorted() {
            if let img = NSImage(contentsOf: dir.appendingPathComponent(f)),
               let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                out.append(cg)
            }
        }
        return out
    }
    let c: CGFloat = 60
    let L: CGFloat = 30
    let wallY: CGFloat = -40.5  // 墙面/天花板在本地坐标系里的接触线

    var state: State = .idleBall
    /// 双击待机球掉落 / 掉落过程中显示图标
    var iconFall = false
    private var isIdleBall: Bool {
        if case .idleBall = state { return true }
        return false
    }
    var origin: CGPoint = .zero
    var phase: Double = 0
    var occludesHead = false
    var paused = false
    var theta: CGFloat = 0
    var fallV: CGFloat = 0
    var sitWindowID: CGWindowID = 0
    var sitHostLayer = 0
    var sitOneLevelAbove = false  // false=正常遮挡（被宿主前面的窗口盖住）；true=坐窗时永远置顶
    /// 坐窗时"压在宿主前面的那些窗口"在本视图坐标里的矩形：绘制时按这些矩形裁掉，
    /// 从而在不依赖（跨进程无效的）窗口排序 API 的前提下得到真实的遮挡关系
    var coverRects: [CGRect] = []
    var sitRelX: CGFloat = 0  // 坐下时相对宿主窗口左缘的水平偏移，用于跟随窗口左右移动
    /// 坐窗姿势：false=坐姿摇头晃脚（宿主顶边在屏幕下半，窗口加高132、origin.y=宿主顶-58）
    /// true=躺姿（宿主顶边在屏幕上半，窗口120、origin.y=宿主顶-46，身体直线贴宿主顶边）
    var sitLie = false
    let speed: CGFloat = 50
    var tickCount = 0
    var netTick = 0
    var timer: Timer?

    // 行走中的随机行为：走一段时间后偶尔停下沉思或挥手
    var walkDir = 1
    var walkClock: Double = 0
    var nextBehaviorAt: Double = 14
    var behaviorElapsed: Double = 0
    var behaviorDuration: Double = 0

    /// 距上次落地的秒数（用于落地挤压回弹）
    var landingT: CGFloat = 99

    private var grabOffset: CGPoint?
    private var dragStartScreen: NSPoint?
    private var isDragGesture = false
    /// 单击后延迟弹出的菜单（双击时取消，免得菜单吃掉第二击）
    private var pendingMenu: DispatchWorkItem?
    /// 全局鼠标监听（点别处继续）
    private var globalClickMonitor: Any?

    // ---------- 手绘气泡 ----------
    var bubbleWindow: BubbleWindow?
    var bubbleText: String?
    var bubbleUntil: Double = 0
    var nextBubbleAt: Double = 5
    var elapsed: Double = 0          // 累计运行秒数（气泡调度用）
    var lastHeadC: CGPoint = CGPoint(x: 0, y: 30)   // 最近一帧头部在绘图坐标里的位置
    var lastSquashY: CGFloat = 1                    // 最近一帧的纵向挤压量（气泡定位用）
    var autoBubble = true            // 自动冒话开关（控制总线 mute 用）
    var spriteClock: Double = 0      // 手绘贴图的播放计时（秒）
    private var control: ControlServer?

    /// 一条柔软肢体：从 a 到 b 的曲线，bend 是向法线方向的鼓出量（正负决定弯向哪边）
    struct Limb {
        var a: CGPoint
        var b: CGPoint
        var bend: CGFloat
    }

    // 上一帧的肢体端点与弯曲量，用于按"末端相对速度"计算惯性滞后
    private var prevMain: [(CGPoint, CGPoint)] = []
    private var prevMainBend: [CGFloat] = []
    private var prevFront: [(CGPoint, CGPoint)] = []
    private var prevFrontBend: [CGFloat] = []

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private var signalSources: [DispatchSourceSignal] = []

    /// 退出时清掉自己的 socket 文件。
    /// 不做这件事的后果很具体：程序被杀（pkill / 注销 / 崩溃）后 /tmp/stickman.sock 会留下，
    /// 而这个文件的属主是"当前用户"。同一台 Mac 换另一个用户登录后，那个人既连不上它
    /// （0600），也用 unlink 删不掉（/tmp 的 sticky bit），新实例就会误判成"已有实例"。
    private func installTerminationCleanup() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.control?.stop()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    /// 正常退出路径（⌘Q / Dock 右键退出）也走这里
    func shutdown() {
        control?.stop()
        control = nil
    }

    func start(at o: CGPoint) {
        origin = o
        nextBehaviorAt = Double.random(in: 8...18)
        nextBubbleAt = Double.random(in: 4...8)   // 首个气泡早点出现
        let bw = BubbleWindow()
        bw.setFrameOrigin(NSPoint(x: o.x, y: o.y + 130))
        bw.orderFrontRegardless()
        bubbleWindow = bw
        sitLog("launched args=\(CommandLine.arguments.joined(separator: " "))")
        installResumeWatchers()

        // 本地控制总线：任何脚本（或 AI）可以通过它让它说话、做动作。
        // 单实例守卫②（守卫①的兜底，防 LaunchServices 竞态）：
        //   只有"探测到同用户的活实例"才退出自己。路径不可用——典型是 /tmp 里躺着
        //   另一个 macOS 用户留下的 socket，0600 连不上、sticky bit 又删不掉——
        //   属于附加能力缺失，桌宠本身完全能跑，绝不能因此让进程静默退出。
        let ctl = ControlServer(paths: ControlServer.defaultPaths)
        switch ctl.start(handler: { [weak self] tokens in
            self?.handleControl(tokens) ?? ["ok": "0", "err": "gone"]
        }) {
        case .ok:
            control = ctl
        case .anotherInstance:
            exit(0)
        case .unavailable:
            NSLog("control: debug interface disabled; pet continues without it")
        }
        installTerminationCleanup()
        // 调试：直接进入某个姿态，便于截图核对
        if CommandLine.arguments.contains("--top") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.state = .crawlingTop(dir: 1)
            }
        }
        if CommandLine.arguments.contains("--ponder") || CommandLine.arguments.contains("--wave") {
            let wantPonder = CommandLine.arguments.contains("--ponder")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self else { return }
                self.state = wantPonder ? .pondering : .waving
                self.behaviorElapsed = 0
                self.behaviorDuration = 3600
                self.phase = 0
            }
        }
        if CommandLine.arguments.contains("--sit-front") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.debugSitFront() }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--sit-on"), i + 1 < CommandLine.arguments.count,
           let id = UInt32(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.debugSit(on: CGWindowID(id)) }
        }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - 控制总线（外部操控动作与对话）
    @discardableResult
    func speak(_ text: String, dur: Double = 5) -> Bool {
        guard !text.isEmpty, !isIdleBall else { return false }   // 待机球形态无任何气泡
        let d = max(1, min(dur, 120))
        bubbleText = text
        bubbleUntil = elapsed + d
        // 手动说话后，把下一次自动气泡推远，免得立刻被自己的随机台词打断
        nextBubbleAt = elapsed + d + Double.random(in: 6...10)
        return true
    }

    private func handleControl(_ t: [String]) -> [String: String] {
        guard let cmd = t.first?.lowercased() else { return ["ok": "0", "err": "empty"] }
        var rest = Array(t.dropFirst())
        switch cmd {
        case "say", "sayf":
            var dur: Double = 5
            if cmd == "sayf", let f = rest.first.flatMap(Double.init) {
                dur = f
                rest.removeFirst()
            }
            let text = rest.joined(separator: " ")
            guard speak(text, dur: dur) else {
                return ["ok": "0", "err": isIdleBall ? "idle-no-bubble" : "empty-text"]
            }
            return ["ok": "1", "said": text]
        case "do":
            guard let a = rest.first?.lowercased() else { return ["ok": "0", "err": "no-action"] }
            if a == "droptest" {   // 调试：模拟拖动后在某条边附近松手
                let edge = rest.count > 1 ? rest[1].lowercased() : "center"
                guard ["left", "right", "top", "center", "nearwin"].contains(edge) else {
                    return ["ok": "0", "err": "usage: do droptest left|right|top|center|nearwin"]
                }
                return dropTest(edge)
            }
            let secs = rest.count > 1 ? (Double(rest[1]) ?? 0) : 0
            return performAction(a, seconds: secs)
        case "face":
            let d = rest.first?.lowercased() ?? ""
            guard d == "left" || d == "right" else { return ["ok": "0", "err": "bad-dir"] }
            walkDir = (d == "right") ? 1 : -1
            if case .walking = state { state = .walking(dir: walkDir) }
            if case .crawlingTop = state { state = .crawlingTop(dir: walkDir) }
            return ["ok": "1", "dir": d]
        case "mute":
            autoBubble = false
            return ["ok": "1", "autoBubble": "0"]
        case "front":
            sitOneLevelAbove.toggle()   // 调试/验证用：坐窗时是否置顶（同菜单项）
            if sitOneLevelAbove, !coverRects.isEmpty { coverRects.removeAll() }  // 清幽灵裁剪矩形
            return ["ok": "1", "sitOneLevelAbove": sitOneLevelAbove ? "1" : "0"]
        case "unmute":
            autoBubble = true
            nextBubbleAt = elapsed + 8
            return ["ok": "1", "autoBubble": "1"]
        case "lang":
            guard let m = rest.first?.lowercased(), ["system", "zh", "en"].contains(m) else {
                return ["ok": "0", "err": "usage: lang system|zh|en"]
            }
            applyLanguage(m)
            return ["ok": "1", "lang": L10n.lang.rawValue, "mode": L10n.mode]
        case "state":
            return currentStateInfo()
        case "menu":
            // 调试：把功能菜单的标题按当前语言导出来（核对本地化是否生效）
            let items = buildMenu().items.map { it -> String in
                if it.isSeparatorItem { return "---" }
                if let sub = it.submenu {
                    return it.title + "(" + sub.items.map { $0.title }.joined(separator: "/") + ")"
                }
                return it.title
            }
            return ["ok": "1", "lang": L10n.lang.rawValue, "mode": L10n.mode,
                    "system": L10n.systemLang.rawValue,
                    "menu": items.joined(separator: " | ")]
        case "net":
            return ["ok": "1", "net": SystemStats.netDebug(),
                    "text": SystemStats.networkSpeedText() ?? "nil"]
        default:
            return ["ok": "0", "err": "unknown-cmd",
                    "cmds": "say,sayf,do,face,mute,unmute,state,net,lang,menu"]
        }
    }

    private func performAction(_ a: String, seconds: Double) -> [String: String] {
        func begin(_ s: State, _ d: Double) {
            state = s
            phase = 0
            spriteClock = 0
            behaviorElapsed = 0
            behaviorDuration = d > 0 ? d : 6
        }
        switch a {
        case "walk", "stand-up":
            state = .walking(dir: walkDir)
            walkClock = 0
            nextBehaviorAt = 60
            return ["ok": "1", "act": "walk"]
        case "ponder":
            begin(.pondering, seconds)
            return ["ok": "1", "act": "ponder"]
        case "wave", "greet":
            begin(.waving, seconds > 0 ? seconds : 3.0)   // 12帧×2圈@8fps
            return ["ok": "1", "act": "wave"]
        case "blush":
            begin(.blushing, seconds > 0 ? seconds : 1.0) // 8帧×1圈@8fps
            return ["ok": "1", "act": "blush"]
        case "sit", "sleep":
            debugSitFront()
            return ["ok": "1", "act": "sit"]
        case "lie", "lying":
            debugSitFront(lie: true)
            return ["ok": "1", "act": "lie"]
        case "top", "hang":
            state = .crawlingTop(dir: walkDir)
            phase = 0
            return ["ok": "1", "act": "top"]
        case "climb", "climb-up":
            begin(.climbing(side: walkDir >= 0 ? 1 : -1, up: true), seconds > 0 ? seconds : 30)
            nextBehaviorAt = 60
            return ["ok": "1", "act": "climb", "side": walkDir >= 0 ? "right" : "left"]
        case "idle", "ball":
            enterIdle()
            return ["ok": "1", "act": "idle"]
        case "selftest-fall":   // 调试：等价于双击待机球（合成鼠标事件无辅助功能权限时用）
            guard case .idleBall = state else { return ["ok": "0", "err": "not-idle"] }
            iconFall = true
            fallV = 0
            state = .falling
            return ["ok": "1", "act": "selftest-fall"]
        case "left", "right":
            walkDir = (a == "right") ? 1 : -1
            state = .walking(dir: walkDir)
            return ["ok": "1", "act": a]
        case "stand":
            begin(.pondering, seconds > 0 ? seconds : 5)
            return ["ok": "1", "act": "stand"]
        default:
            return ["ok": "0", "err": "bad-action",
                    "actions": "walk,ponder,wave,blush,sit,top,climb,idle,left,right,stand"]
        }
    }

    private func currentStateInfo() -> [String: String] {
        var name = "unknown"
        switch state {
        case let .walking(d): name = "walking(dir:\(d))"
        case let .climbing(s, u): name = "climbing(side:\(s),up:\(u))"
        case let .crawlingTop(d): name = "crawlingTop(dir:\(d))"
        case .sitting: name = sitLie ? "lying" : "sitting"
        case .falling: name = "falling"
        case .dragged: name = "dragged"
        case .pondering: name = "pondering"
        case .idleBall: name = "idleBall"
        case .waving: name = "waving"
        case .blushing: name = "blushing"
        }
        return ["ok": "1", "state": name,
                "bubble": bubbleText ?? "",
                "paused": paused ? "1" : "0",
                "level": window.map { String($0.level.rawValue) } ?? "?",
                "autoBubble": autoBubble ? "1" : "0"]
    }

    /// 调试：直接坐到最前面的可用窗口顶边，用于自动验证层级
    /// 进入待机：球拴在屏幕顶边、挂在左上角甩圈（默认状态）
    func enterIdle() {
        guard !PetView.idleFrames.isEmpty else {
            beginWalking(1)     // 资源缺失兜底：直接正常活动
            return
        }
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let vf = screen.frame
        state = .idleBall
        paused = false          // 回待机必须立刻开始甩圈（点菜单前可能处于暂停态）
        theta = 0
        fallV = 0
        iconFall = false
        phase = 0
        spriteClock = 0
        bubbleText = nil        // 待机不冒泡
        // 窗口顶部=可见区顶(菜单栏下缘, 刘海机约38pt)，绳拴在那条边上；挂点在窗口顶部中心
        origin = CGPoint(x: vf.minX + 24, y: screen.visibleFrame.maxY - PetView.side)
        window?.setFrameOrigin(origin)
        needsDisplay = true
    }

    private func debugSitFront(lie: Bool = false) {
        guard let w = onScreenWindows().first else { return }
        debugSit(on: w.id, lie: lie)
    }

    private func debugSit(on id: CGWindowID, lie: Bool = false) {
        guard let w = locateWindow(id), let win = window else { return }
        sitWindowID = w.id
        sitHostLayer = w.layer
        sitRelX = min(max((w.maxX - w.minX) / 2, 25), (w.maxX - w.minX) - 25)
        sitLie = lie
        origin = CGPoint(x: w.minX + sitRelX - 60, y: w.top - (lie ? 46 : 58))
        state = .sitting
        win.setFrameOrigin(origin)
        sitLog("debug sit host=\(w.id) pose=\(lie ? "lie" : "sit") layer=\(w.layer)")
    }

    private func tick() {
        guard let win = window, let screen = win.screen ?? NSScreen.main else { return }
        // 睡姿：与宿主窗口同一层级，再用"贴住"逻辑保持在它正上方，
        // 一旦有窗口盖住他，就允许被压住（真正的遮挡关系）
        var isSitting = false
        if case .sitting = state { isSitting = true }
        // 坐窗：普通窗口层(0) + 逐帧裁掉"压在宿主前面的窗口"，得到真实遮挡关系。
        // （NSWindow.order(relativeTo: 别的App窗口) 跨进程是空操作，日志已实测无效，故改用裁剪法）
        let wantLevel: NSWindow.Level = isSitting
            ? (sitOneLevelAbove ? NSWindow.Level(rawValue: 1) : NSWindow.Level(rawValue: 0))
            : .statusBar
        if win.level != wantLevel { win.level = wantLevel }
        // 打招呼跳跃需要头部空间：窗口临时加高到 160（底边不动，向上长），结束自动缩回；
        // 手绘坐姿需要腿部垂落空间：窗口加高到 132（底边不动向上长）
        var greetActive = false
        if case .waving = state, !PetView.greetFrames.isEmpty { greetActive = true }
        let sitSpriteTall = isSitting && !sitLie && !PetView.sitFrames.isEmpty
        let wantH: CGFloat = greetActive ? 160 : (sitSpriteTall ? 132 : PetView.side)
        if abs(win.frame.height - wantH) > 0.5 {
            win.setFrame(NSRect(origin: win.frame.origin, size: NSSize(width: PetView.side, height: wantH)), display: false)
        }
        if isSitting {
            if !sitOneLevelAbove {
                tickCount += 1
                if tickCount == 1 || tickCount % 6 == 0 {
                    updateSitOcclusion(win: win)
                    syncBubbleOcclusion()
                }
            } else {
                syncBubbleOcclusion()          // 坐窗置顶开启：气泡也不必裁
            }
        } else {
            tickCount = 0
            if !coverRects.isEmpty { coverRects.removeAll() }
            syncBubbleOcclusion()
        }
        let vf = screen.frame
        // ---------- 气泡调度 ----------
        // 待机球形态：无任何气泡
        elapsed += 1.0 / 60.0
        // 网速：独立按 0.5 秒节奏采样（不能等"要冒泡时"才取，间隔不定会让速率算错）
        netTick += 1
        if netTick % 30 == 1 { SystemStats.pump() }
        if !paused, autoBubble, !isIdleBall, elapsed >= nextBubbleAt {
            nextBubbleAt = elapsed + Double.random(in: 7...15)
            if let msg = makeBubbleText() {
                bubbleText = msg
                bubbleUntil = elapsed + 3
            }
        }
        if bubbleText != nil, elapsed >= bubbleUntil { bubbleText = nil }
        updateBubble()
        if !paused {
            let dt: CGFloat = 1.0 / 60.0
            landingT += dt
            switch state {
            case .walking:
                phase += 0.13
                spriteClock += Double(dt)   // 手绘行走帧 8fps 计时
                step(vf, dt)
                // 走够一段时间，偶尔停下来做点别的
                walkClock += Double(dt)
                if walkClock >= nextBehaviorAt { beginBehavior() }
            case .pondering:
                // 慢节奏：呼吸起伏 + 轻微摇晃
                phase += 0.05
                spriteClock += Double(dt)
                behaviorElapsed += Double(dt)
                if behaviorElapsed >= behaviorDuration { endBehavior() }
            case .waving:
                phase += 0.18
                spriteClock += Double(dt)      // 打招呼贴图 8fps 计时（矢量兜底用 phase）
                behaviorElapsed += Double(dt)
                if behaviorElapsed >= behaviorDuration { endBehavior() }
            case .blushing:
                phase += 0.13
                spriteClock += Double(dt)      // 脸红贴图 8fps 计时
                behaviorElapsed += Double(dt)
                if behaviorElapsed >= behaviorDuration { endBehavior() }
            case .climbing, .crawlingTop:
                phase += 0.13
                // 贴图模式 8fps 计时（攀行帧所有画面位置一致，计时驱动帧序即可）
                let spriteMode: Bool = {
                    if case .climbing = state { return !PetView.climbFrames.isEmpty }
                    return !PetView.crawlTopFrames.isEmpty
                }()
                if spriteMode { spriteClock += Double(dt) }
                step(vf, dt)
            case .sitting:
                phase += 0.025
                spriteClock += Double(dt)   // 手绘坐/躺贴图 8fps 计时（漏加会冻在第一帧，晃脚/鼻涕泡全没了）
                if let f = locateWindow(sitWindowID) {
                    origin.y = f.top - (sitLie ? 46 : 58)
                    origin.x = f.minX + sitRelX - 60
                    win.setFrameOrigin(origin)
                } else {
                    // 宿主窗口被关掉：和被拖走一样以球形态掉下去，落地才展开
                    iconFall = true
                    fallV = 0
                    state = .falling
                }
            case .idleBall:
                // 待机：只播甩圈动画，位置钉在屏幕顶边左上角，不移动不产生行为
                spriteClock += Double(dt)
            case .falling:
                phase += 0.08
                fallV = min(fallV + 1800 * dt, 900)
                origin.y -= fallV * dt
                if origin.y <= vf.minY - 16 {
                    origin.y = vf.minY - 16
                    fallV = 0
                    landingT = 0        // 触发落地挤压
                    iconFall = false
                    beginWalking(1)
                }
            case .dragged:
                phase += 0.05
            }
            let target: CGFloat = {
                switch state {
                // 贴图模式攀爬不旋转（帧本身就是竖直姿态），矢量兜底才转 90°
                case .climbing(let s, _): return PetView.climbFrames.isEmpty ? CGFloat(s) * .pi / 2 : 0
                case .crawlingTop: return PetView.crawlTopFrames.isEmpty ? .pi : 0
                default: return 0
                }
            }()
            var d = target - theta
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            theta += d * 0.18
            constrain(vf)
            win.setFrameOrigin(origin)
        }
        needsDisplay = true
    }

    private func step(_ vf: NSRect, _ dt: CGFloat) {
        let move = speed * dt
        switch state {
            case .walking(let dir):
                origin.x += CGFloat(dir) * move
                if PetView.climbFrames.isEmpty {
                    if origin.x <= vf.minX - 26 { state = .climbing(side: -1, up: true) }
                    else if origin.x >= vf.maxX - 94 { state = .climbing(side: 1, up: true) }
                } else {
                    // 贴图模式：窗口缘=屏幕缘=触须末端，走到窗口贴边再切入攀爬
                    if origin.x <= vf.minX { state = .climbing(side: -1, up: true) }
                    else if origin.x >= vf.maxX - PetView.side { state = .climbing(side: 1, up: true) }
                }
        case .idleBall:
            break   // 待机不移动
        case .climbing(let side, let up):
            origin.y += up ? move : -move
            if up && origin.y >= vf.maxY - 104 {
                state = .crawlingTop(dir: side == 1 ? -1 : 1)
            } else if !up && origin.y <= vf.minY - 16 {
                beginWalking(side == 1 ? -1 : 1)
            }
        case .crawlingTop(let dir):
            origin.x += CGFloat(dir) * move
            if PetView.crawlTopFrames.isEmpty {
                if origin.x <= vf.minX - 30 { state = .climbing(side: -1, up: false) }
                else if origin.x >= vf.maxX - 90 { state = .climbing(side: 1, up: false) }
            } else {
                // 贴图模式：窗口缘=屏幕缘，整窗走到边再切入侧爬
                if origin.x <= vf.minX { state = .climbing(side: -1, up: false) }
                else if origin.x >= vf.maxX - PetView.side { state = .climbing(side: 1, up: false) }
            }
        case .falling, .dragged, .sitting, .pondering, .waving, .blushing:
            break
        }
    }

    /// 按当前状态挑一条气泡内容
    private func makeBubbleText() -> String? {
        switch state {
        case .walking, .climbing, .crawlingTop:
            if Double.random(in: 0..<1) < 0.55, let s = SystemStats.networkSpeedText() {
                return T("网速 \(s)", "Net \(s)")
            }
            return SystemStats.batteryText()
        case .sitting:
            // 中文保留 vivo50 彩蛋（与体温各一半）；英文不玩这个梗，只冒实用信息
            if L10n.lang == .zh {
                return Double.random(in: 0..<1) < 0.5 ? "vivo50" : SystemStats.thermalText()
            }
            return [SystemStats.networkSpeedText(), SystemStats.batteryText(), SystemStats.thermalText()]
                .compactMap { $0 }
                .randomElement()
        default:
            return nil
        }
    }

    /// 头部在屏幕上的坐标：绘图坐标 → 水平镜像 → 挤压（绕脚底支点） → 旋转 → 视图坐标 → 加窗口原点
    private var headScreenPoint: CGPoint? {
        guard let w = window else { return nil }
        var p = lastHeadC
        var fx = false
        if case .walking(let wd) = state { fx = wd == -1 }
        if case .climbing(let sd, let up) = state {
            // 贴图模式：头心在 draw 时已按侧别镜像，这里不再翻；矢量兜底维持旧逻辑
            fx = PetView.climbFrames.isEmpty ? (up != (sd == 1)) : false
        }
        if fx { p.x = -p.x }
        if abs(lastSquashY - 1) > 0.0008 { p.y = -40 + (p.y + 40) * lastSquashY }
        let ct = cos(theta), st = sin(theta)
        let vp = CGPoint(x: c + p.x * ct - p.y * st, y: c + p.x * st + p.y * ct)
        let f = w.frame
        return CGPoint(x: f.minX + vp.x, y: f.minY + vp.y)
    }

    /// 气泡锚点平滑值：动画 8fps 逐帧跳头心，60Hz 直跟会抖；
    /// 用指数趋近让气泡"缓移"向头心（换话/瞬移时直接吸附）
    private var bubbleAnchor: CGPoint?

    /// 气泡跟随：尾巴尖沿贴图自身的尾巴朝向，精确指向头部中心（不错位）；
    /// 在水平/垂直四种翻转里挑一个既能整个放进屏幕、又不遮住小人的摆放；
    /// 贴图只做等比缩放 + 整体平移，形状在说话期间永不变。
    private func updateBubble() {
        guard let bw = bubbleWindow else { return }
        let wasVisible = bw.isVisible
        let bv = bw.view
        bv.text = bubbleText
        let target: CGFloat = bubbleText == nil ? 0 : 1
        bv.alpha += (target - bv.alpha) * 0.14

        if bv.alpha < 0.02 {
            if bw.isVisible { bw.orderOut(nil) }
            bubbleAnchor = nil        // 重新开口时从头心当前位置起算
            return
        }
        if !bw.isVisible { bw.orderFrontRegardless() }
        bw.alphaValue = bv.alpha
        guard !BubbleView.bubbles.isEmpty else { return }

        let vf = (window?.screen ?? NSScreen.main)?.frame ?? NSScreen.main!.frame
        let rawHead = headScreenPoint ?? CGPoint(x: origin.x + 60, y: origin.y + 90)
        // 平滑：每帧向真实头心趋近 8%（60Hz 下约 0.2s 跟上），
        // 8fps 的逐帧跳变被抹平；距离突变 >24pt（换话/瞬移/起立）时直接吸附
        if let a = bubbleAnchor, bv.textKey == bubbleText {
            let d = hypot(rawHead.x - a.x, rawHead.y - a.y)
            bubbleAnchor = d > 24 ? rawHead
                : CGPoint(x: a.x + (rawHead.x - a.x) * 0.08, y: a.y + (rawHead.y - a.y) * 0.08)
        } else {
            bubbleAnchor = rawHead
        }
        let headPt = bubbleAnchor!
        let tipDist = PetView.headR + 22     // 尾巴尖到头中心：头半径 + 一个头径再余一点（贴顶时不显挤）
        // 小人身形矩形：矢量姿态用局部包围盒(-38..38,-46..50)；
        // 贴图爬行的实际内容更小且贴边偏移（视图 x 40..120, y 44..76），用真实盒避免误罚
        let corners: [CGPoint]
        if case .climbing = state, !PetView.climbFrames.isEmpty {
            corners = [CGPoint(x: -20, y: -16), CGPoint(x: 60, y: -16),
                       CGPoint(x: -20, y: 16), CGPoint(x: 60, y: 16)]
        } else if case .sitting = state, sitLie, !PetView.lieFrames.isEmpty {
            // 躺姿身形横贯：视图 x 28..106、y 16..74 → 相对中心 (-32,-44)..(46,14)
            corners = [CGPoint(x: -32, y: -44), CGPoint(x: 46, y: -44),
                       CGPoint(x: -32, y: 14), CGPoint(x: 46, y: 14)]
        } else {
            corners = [CGPoint(x: -38, y: -46), CGPoint(x: 38, y: -46),
                       CGPoint(x: -38, y: 50), CGPoint(x: 38, y: 50)]
        }
        let wf = window?.frame ?? NSRect(x: origin.x, y: origin.y,
                                         width: PetView.side, height: PetView.side)
        let ct = cos(theta), st = sin(theta)
        var fx0 = CGFloat.greatestFiniteMagnitude, fx1 = -fx0
        var fy0 = fx0, fy1 = fx1
        for corner in corners {
            let vx = c + corner.x * ct - corner.y * st
            let vy = c + corner.x * st + corner.y * ct
            fx0 = min(fx0, vx); fx1 = max(fx1, vx)
            fy0 = min(fy0, vy); fy1 = max(fy1, vy)
        }
        let petFig = CGRect(x: wf.minX + fx0, y: wf.minY + fy0,
                            width: fx1 - fx0, height: fy1 - fy0)

        let text = bubbleText ?? ""
        // 逐张气泡、逐翻转评估摆放质量；换话时在"几乎同样好"的气泡里随机挑一张
        // （贴屏幕边时有的气泡天生对不准头，按当前几何择优，兼顾变化感）；
        // 同一句话沿用已选气泡，摆放随小人移动实时重算。
        // 打分：头不被盖（绝对） > 不碰身形 > 尾巴不错位(平移量) > 悬在头上方。
        struct Placement { let score: CGFloat; let flip: (Bool, Bool); let frame: CGRect; let size: NSSize; let scale: CGFloat }
        var perIndex: [Placement?] = Array(repeating: nil, count: BubbleView.bubbles.count)
        let headTopSpace = vf.maxY - headPt.y - tipDist
        let savedIndex = bv.index          // 评估会临时改 bv.index，结束后必须恢复
        for idx in 0..<BubbleView.bubbles.count {
            bv.index = idx
            var size = bv.fitSize(for: text)
            // 头顶空间不足（坐窗贴屏幕顶）时按可用高度收缩气泡——宁可小，也不挤到头下方遮住身体
            if size.height - 10 > headTopSpace, headTopSpace > 20 {
                size = bv.fitSize(for: text, scaleMul: max(0.55, (headTopSpace + 10) / size.height))
            }
            var best = Placement(score: .greatestFiniteMagnitude, flip: (false, false),
                                 frame: .zero, size: size, scale: bv.scale)
            for flip in [(false, false), (true, false), (false, true), (true, true)] {
                bv.flipX = flip.0
                bv.flipY = flip.1
                let tail = bv.tailPoint
                let dir = bv.tailDir()
                let tip = CGPoint(x: headPt.x - dir.x * tipDist, y: headPt.y - dir.y * tipDist)
                let ideal = CGPoint(x: tip.x - tail.x, y: tip.y - tail.y)
                // 极端贴边时只整体平移进屏幕（保形状），平移量算进错位扣分
                let ox = min(max(ideal.x, vf.minX + 2), vf.maxX - size.width - 2)
                let oy = min(max(ideal.y, vf.minY + 2), vf.maxY - size.height - 2)
                let frame = CGRect(x: ox, y: oy, width: size.width, height: size.height)
                let shift = hypot(ox - ideal.x, oy - ideal.y)
                // 精确遮挡判定：头中心（含头圆边缘 4 个探点）落在实心像素上 = 绝对否决；
                // 身形矩形碰到实心像素 = 重罚
                let headLocal = CGPoint(x: headPt.x - ox, y: headPt.y - oy)
                var headCovered = bv.bodyContains(headLocal)
                if !headCovered {
                    for dxp in [CGFloat(-6), CGFloat(6)] {
                        if bv.bodyContains(CGPoint(x: headLocal.x + dxp, y: headLocal.y))
                            || bv.bodyContains(CGPoint(x: headLocal.x, y: headLocal.y + dxp)) {
                            headCovered = true; break
                        }
                    }
                }
                let overlapsPet = bv.bodyIntersects(CGRect(x: petFig.minX - ox, y: petFig.minY - oy,
                                                           width: petFig.width, height: petFig.height))
                let above = frame.midY >= headPt.y
                let score = (headCovered ? 100_000 : 0) + (overlapsPet ? 1_000 : 0)
                    + shift * 20 + (above ? 0 : 40)
                if score < best.score {
                    best = Placement(score: score, flip: flip, frame: frame, size: size, scale: bv.scale)
                }
            }
            perIndex[idx] = best
        }
        bv.index = savedIndex

        if bv.textKey != bubbleText {
            bv.textKey = bubbleText
            let minScore = perIndex.compactMap { $0?.score }.min() ?? 0
            if ProcessInfo.processInfo.environment["PET_DBG"] != nil {
                let s = perIndex.map { $0.map { String(format: "%.0f(%.0fx%.0f)", $0.score, $0.size.width, $0.size.height) } ?? "nil" }
                sitLog("dbg pick text=\(bubbleText ?? "nil") head=(\(Int(headPt.x)),\(Int(headPt.y))) scores=\(s.joined(separator: ","))")
            }
            let good = perIndex.enumerated().compactMap { (i, p) -> Int? in
                (p != nil && p!.score <= minScore + 60) ? i : nil
            }
            bv.index = good.randomElement() ?? 0
        }
        guard let choice = perIndex[bv.index] else { return }
        bv.flipX = choice.flip.0
        bv.flipY = choice.flip.1
        bv.scale = choice.scale      // 评估循环会动 bv.scale，恢复成选定气泡的值，尾巴换算才准
        bw.setContentSize(choice.size)
        if ProcessInfo.processInfo.environment["PET_DBG"] != nil {
            let tp = CGPoint(x: choice.frame.minX + bv.tailPoint.x,
                             y: choice.frame.minY + bv.tailPoint.y)
            let td = bv.tailDir()
            let d = hypot(tp.x - headPt.x, tp.y - headPt.y)
            sitLog(String(format: "dbg head=(%.0f,%.0f) theta=%.2f lastHeadC=(%.1f,%.1f) idx=%d flip=(%d,%d) tip=(%.0f,%.0f) dist=%.1f dir=(%.2f,%.2f) frame=(%.0f,%.0f,%.0f,%.0f) score=%.0f",
                          headPt.x, headPt.y, theta, lastHeadC.x, lastHeadC.y,
                          bv.index, choice.flip.0 ? 1 : 0, choice.flip.1 ? 1 : 0,
                          tp.x, tp.y, d, td.x, td.y,
                          choice.frame.minX, choice.frame.minY, choice.frame.width, choice.frame.height, choice.score))
        }
        bw.setFrameOrigin(choice.frame.origin)
        bw.level = window?.level ?? .statusBar
        // 刚露头就按最终位置算一次该挖的洞：否则最多 0.1s 内气泡会整块浮在前窗上面闪一下
        if !wasVisible { syncBubbleOcclusion() }
    }


    /// 开始行走，并重置"下次要不要停下来做点别的"的计时
    private func beginWalking(_ dir: Int) {
        walkDir = dir
        state = .walking(dir: dir)
        walkClock = 0
        nextBehaviorAt = Double.random(in: 8...18)
    }

    /// 走着走着，随机决定停下来沉思或打招呼
    private func beginBehavior() {
        if Double.random(in: 0..<1) < 0.62 {
            state = .pondering
            behaviorDuration = Double.random(in: 3...20)   // 站定沉思 3–20 秒
        } else {
            state = .waving
            behaviorDuration = PetView.greetFrames.isEmpty ? 3.6 : 3.0   // 打招呼 12帧×2圈@8fps
        }
        behaviorElapsed = 0
        phase = 0
        spriteClock = 0
    }

    private func endBehavior() {
        beginWalking(walkDir)
    }

    private func constrain(_ vf: NSRect) {
        // 接触点：身体中心 + 旋转后的"接触方向"偏移，钉在所在边上。
        // 地面姿态脚底画在本地 y=-38，用 38 才能精确贴边（44 会悬空 6px）；
        // 攀爬/顶挂的墙面接触几何仍是 44。
        switch state {
        case .walking, .pondering, .waving, .blushing:
            origin.y = vf.minY - (c - 38 * cos(theta))
        case .climbing(let side, _):
            if PetView.climbFrames.isEmpty {
                origin.x = (side == 1 ? vf.maxX : vf.minX) - (c + 44 * sin(theta))
            } else {
                theta = 0   // 贴图攀爬始终竖直，头心镜像在 draw 时做，头点不做二次旋转
                origin.x = side == 1 ? vf.maxX - PetView.side : vf.minX
            }
        case .crawlingTop:
            if PetView.crawlTopFrames.isEmpty {
                origin.y = vf.maxY - (c - 44 * cos(theta))
            } else {
                theta = 0   // 贴图攀行保持正立，手尖（画布顶）压进屏幕顶边 2pt
                origin.y = vf.maxY - PetView.side + 2
            }
        case .sitting, .falling, .dragged, .idleBall:
            break
        }
    }

    private struct HostWindow { let id: CGWindowID; let top: CGFloat; let minX: CGFloat; let maxX: CGFloat; let layer: Int }

    private func onScreenWindows() -> [HostWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let myPID = ProcessInfo.processInfo.processIdentifier
        var out: [HostWindow] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int, pid != myPID,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let bxn = (b["X"] as? NSNumber)?.doubleValue,
                  let byn = (b["Y"] as? NSNumber)?.doubleValue,
                  let bwn = (b["Width"] as? NSNumber)?.doubleValue, bwn > 150,
                  let bhn = (b["Height"] as? NSNumber)?.doubleValue, bhn > 100,
                  let idn = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            out.append(HostWindow(id: CGWindowID(idn), top: primaryH - CGFloat(byn), minX: CGFloat(bxn), maxX: CGFloat(bxn + bwn), layer: layer))
        }
        return out
    }

    private func findWindowTopNear(_ p: CGPoint) -> HostWindow? {
        onScreenWindows()
            .filter { p.x >= $0.minX + 10 && p.x <= $0.maxX - 10 && abs(p.y - $0.top) < 60 }
            .min { abs(p.y - $0.top) < abs(p.y - $1.top) }
    }

    private func locateWindow(_ id: CGWindowID) -> HostWindow? {
        onScreenWindows().first { $0.id == id }
    }

    private func sitLog(_ s: String) {
        let path = "/tmp/stickman.log"
        let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(s)\n"
        if let fh = FileHandle(forWritingAtPath: path) { fh.seekToEndOfFile(); fh.write(line.data(using: .utf8)!); fh.closeFile() }
        else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
    }

    /// 坐窗遮挡：找出"排在宿主窗口前面、且和小人相交"的窗口，换算成视图坐标交给 draw 裁掉。
    /// 视觉上就等于"前面的窗口把他盖住了"；前方无遮挡时再把自己提到 layer 0 最前，
    /// 保证他能压在宿主窗口顶边上（跨进程 order(relativeTo:) 实测无效，只能这样做）。
    private func updateSitOcclusion(win: NSWindow) {
        if sitOneLevelAbove {
            if !coverRects.isEmpty { coverRects.removeAll(); needsDisplay = true }
            return
        }
        let wins = layerZeroWindows()
        guard let iHost = wins.firstIndex(where: { $0.id == sitWindowID }) else { return }
        let myID = CGWindowID(win.windowNumber)
        let myFrame = win.frame
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        var rects: [CGRect] = []
        for (i, w) in wins.enumerated() {
            if w.id == myID { continue }
            if w.pid == me { continue }
            if i < iHost, w.frame.intersects(myFrame) { rects.append(w.frame) }
        }
        // 永远把自己提到 layer 0 最前：遮挡交给"擦掉前窗区域"来表现，
        // 这样宿主前面有几层窗口都一样能盖住他（只提一层会漏掉更前面那些）
        let wasFront = wins.first?.id == myID
        if !wasFront { win.orderFrontRegardless() }
        let local = rects.map { $0.offsetBy(dx: -myFrame.minX, dy: -myFrame.minY) }
        if local != coverRects {
            coverRects = local
            needsDisplay = true
            win.displayIfNeeded()      // 提窗与擦除同一帧完成，避免"提上来但还没擦掉"的闪
            if ProcessInfo.processInfo.environment["PET_DBG"] != nil {
                sitLog("sit-occ covers=\(local.count) front=\(wasFront) host=\(iHost)")
            }
        }
    }

    private struct LayerWin { let id: CGWindowID; let pid: Int32; let frame: NSRect }

    /// 气泡层与小人层严格一致：气泡同样提到 layer 0 最前，再用"压在小人前面的那批窗口"
    /// 把气泡一起擦掉。于是前窗挡住小人时也挡住气泡，不会出现"人被挡住、话浮在最上层"。
    private func syncBubbleOcclusion() {
        guard let bw = bubbleWindow else { return }
        guard case .sitting = state, !sitOneLevelAbove else {
            bw.setOccluders(screenRects: [])   // 非"坐普通窗口"：气泡该在最上层，不裁
            return
        }
        let wins = layerZeroWindows()
        guard let iHost = wins.firstIndex(where: { $0.id == sitWindowID }) else {
            bw.setOccluders(screenRects: [])
            return
        }
        let me = Int32(ProcessInfo.processInfo.processIdentifier)
        let f = bw.frame
        var rects: [CGRect] = []
        for (i, w) in wins.enumerated() {
            if i >= iHost { break }                    // 只取排在宿主窗口前面的
            if w.pid == me { continue }                // 自己进程的窗口（小人/气泡）不算
            if w.frame.intersects(f) { rects.append(w.frame) }
        }
        if bw.isVisible, wins.first?.id != CGWindowID(bw.windowNumber) {
            bw.orderFrontRegardless()                  // 与小人同在 layer 0 最前，遮挡交给擦除
        }
        bw.setOccluders(screenRects: rects)
        if ProcessInfo.processInfo.environment["PET_DBG"] != nil {
            let dbg = rects.map { "(\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height)))" }.joined(separator: " ")
            sitLog("bubble-occ n=\(rects.count) b=\(Int(f.minX)),\(Int(f.minY)) rects=[\(dbg)]")
        }
    }

    /// layer 0（普通窗口层）上的窗口，按从前到后排序，屏幕坐标（左下原点）
    private func layerZeroWindows() -> [LayerWin] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        var out: [LayerWin] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = (b["X"] as? NSNumber)?.doubleValue,
                  let y = (b["Y"] as? NSNumber)?.doubleValue,
                  let ww = (b["Width"] as? NSNumber)?.doubleValue,
                  let hh = (b["Height"] as? NSNumber)?.doubleValue,
                  let idn = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  ww > 40, hh > 40 else { continue }
            out.append(LayerWin(id: CGWindowID(idn), pid: Int32(pid),
                                frame: NSRect(x: x, y: primaryH - y - hh, width: ww, height: hh)))
        }
        return out
    }

    override func hitTest(_ p: NSPoint) -> NSView? {
        // 被前窗遮住的部分不接点击，让点击落到下面真正的窗口上
        if coverRects.contains(where: { $0.contains(p) }) { return nil }
        // 待机球热区 = 甩圈轨迹盒（实测球心活动 x 35.7..83 / y 79.3..119.3 + 球半径~10pt 余量）。
        // 不能只跟当前帧：双击掉落的两击间隔约 0.4s，球已甩开 1/3 圈，跟帧热区会让第二击落空穿透。
        // 相比旧热区（26..94 / y≥44）砍掉了上方 22pt 永远碰不到球的死空间，整体小 ~30%。
        if case .idleBall = state {
            return (p.x >= 25 && p.x <= 93 && p.y >= 66) ? self : nil
        }
        // 贴图攀爬：内容盒随侧别镜像——右缘占 x 40..120，左缘占 x 0..80，y 20..100。
        // 热区再往内收 10pt（触须尖在外侧，抓身体即可），比整盒小一圈
        if case .climbing(let sd, _) = state, !PetView.climbFrames.isEmpty {
            let s = PetView.side * PetView.climbScale       // 120 × 2/3 = 80
            let x0 = sd == 1 ? PetView.side - s : 0
            let x1 = sd == 1 ? PetView.side : s
            let y0 = (PetView.side - s) / 2, y1 = y0 + s
            return (p.x >= x0 + 10 && p.x <= x1 - 10 && p.y >= y0 + 8 && p.y <= y1 - 8) ? self : nil
        }
        // 贴图攀行：内容盒画布 x 31..192、y 0..222 → 视口 x 15..96、y 9..120，收紧到 18..94 / y≥14
        if case .crawlingTop = state, !PetView.crawlTopFrames.isEmpty {
            return (p.x >= 18 && p.x <= 94 && p.y >= 14) ? self : nil
        }
        // 手绘坐姿（窗口 132）：人贴窗口上半、腿垂到视图 y≈8，热区下探到 dy≥-52
        if case .sitting = state, !sitLie, !PetView.sitFrames.isEmpty {
            let dx2 = p.x - c, dy2 = p.y - c
            return (dx2 >= -32 && dx2 <= 32 && dy2 >= -52 && dy2 <= 44) ? self : nil
        }
        // 手绘躺姿：身体横贯窗口（内容盒 x 28..106、y 16..74），热区往内收一圈，
        // 窗口边缘留出可穿透点击的余量
        if case .sitting = state, sitLie, !PetView.lieFrames.isEmpty {
            return (p.x >= 38 && p.x <= 96 && p.y >= 24 && p.y <= 66) ? self : nil
        }
        let dx = p.x - c, dy = p.y - c
        let ct = cos(theta), st = sin(theta)
        let lx = dx * ct + dy * st
        let ly = -dx * st + dy * ct
        if lx >= -32, lx <= 32, ly >= -40, ly <= 44 { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        // 第二击落下：取消待弹的菜单，别让菜单吃掉双击
        pendingMenu?.cancel()
        pendingMenu = nil
        // 待机球被双击：以图标形态从当前位置掉到地面，落地开始行走
        if event.clickCount >= 2, case .idleBall = state {
            grabOffset = nil
            dragStartScreen = nil
            isDragGesture = false
            paused = false          // 第一击可能已置为暂停，这里恢复，否则掉落会冻住
            iconFall = true
            fallV = 0
            state = .falling
            return
        }
        let loc = event.locationInWindow
        let sl = win.convertToScreen(NSRect(origin: loc, size: .zero)).origin
        grabOffset = CGPoint(x: win.frame.origin.x - sl.x, y: win.frame.origin.y - sl.y)
        dragStartScreen = sl
        isDragGesture = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let g = grabOffset, let s0 = dragStartScreen else { return }
        let sl = win.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        if !isDragGesture, abs(sl.x - s0.x) > 4 || abs(sl.y - s0.y) > 4 {
            isDragGesture = true
            pendingMenu?.cancel()
            pendingMenu = nil
            paused = false          // 拎起来就恢复活动，别让它悬在半空冻结
            state = .dragged
        }
        guard isDragGesture, let screen = win.screen ?? NSScreen.main else { return }
        let vf = screen.frame
        var o = CGPoint(x: sl.x + g.x, y: sl.y + g.y)
        o.x = min(max(o.x, vf.minX - 40), vf.maxX - 80)
        o.y = min(max(o.y, vf.minY - 40), vf.maxY - 80)
        origin = o
        win.setFrameOrigin(o)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { grabOffset = nil; dragStartScreen = nil }
        if !isDragGesture {
            // 双击的第二击：只解除暂停（真正的动作在 mouseDown 里做了）
            if event.clickCount >= 2 {
                paused = false
                needsDisplay = true
                return
            }
            if paused {
                // 已是暂停态：再点它一下就继续（点别处也会自动继续）
                paused = false
                needsDisplay = true
                return
            }
            // 左键单击：暂停（点别处自动继续），并弹出功能菜单。
            // 待机球例外：单击只弹菜单，甩圈动画照常进行，不暂停
            let p = convert(event.locationInWindow, from: nil)
            var idleClick = false
            if case .idleBall = state { idleClick = true }
            if !idleClick {
                paused = true
                needsDisplay = true
            }
            let work = DispatchWorkItem { [weak self] in self?.showMenu(at: p) }
            pendingMenu = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval * 0.8,
                                          execute: work)
            return
        }
        isDragGesture = false
        guard let win = window else { return }
        finishDrop(win: win)
    }

    /// 松手后的落点判定：窗口顶边→坐下/躺上；贴近屏幕顶边→倒挂；贴近左右边→贴边爬；其余→球态落地
    private func finishDrop(win: NSWindow) {
        let center = CGPoint(x: origin.x + c, y: origin.y + c)
        // 放到某个窗口顶边附近 → 坐上去/躺上去
        if let w = findWindowTopNear(center) {
            sitWindowID = w.id
            sitHostLayer = w.layer
            sitRelX = min(max(center.x - w.minX, 25), (w.maxX - w.minX) - 25)
            // 宿主窗口顶边在屏幕上半 → 躺在窗口上；下半 → 坐在窗口上休息
            let vfNow = (win.screen ?? NSScreen.main)?.frame ?? NSScreen.main!.frame
            sitLie = w.top > vfNow.midY
            origin.y = w.top - (sitLie ? 46 : 58)
            origin.x = w.minX + sitRelX - 60
            state = .sitting
            win.setFrameOrigin(origin)
            sitLog("sit-start host=\(w.id) pose=\(sitLie ? "lie" : "sit") layer=\(w.layer) myNum=\(win.windowNumber) level=\(win.level.rawValue)")
            needsDisplay = true
            return
        }
        // 贴近上边框 → 倒挂；贴近左/右边缘 → 贴边往上爬（拖到边上松手就吸附）
        let vf = (win.screen ?? NSScreen.main)?.frame ?? NSScreen.main!.frame
        let snap: CGFloat = 88
        if vf.maxY - center.y < snap {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - PetView.side)
            state = .crawlingTop(dir: 1)
            constrain(vf)
            win.setFrameOrigin(origin)
            needsDisplay = true
            sitLog("drop-snap top")
            return
        }
        if min(center.x - vf.minX, vf.maxX - center.x) < snap {
            let side: Int = (center.x - vf.minX) < (vf.maxX - center.x) ? -1 : 1
            origin.y = min(max(origin.y, vf.minY - 16), vf.maxY - 104)
            state = .climbing(side: side, up: true)
            constrain(vf)
            win.setFrameOrigin(origin)
            needsDisplay = true
            sitLog("drop-snap side=\(side)")
            return
        }
        // 其它地方松手：保持球的形态往地面掉，落地才展开行走（拖动→掉落视觉连续）
        dropAsBall()
        needsDisplay = true
    }

    /// 调试：模拟一次"在某条边附近松手"（拖动无法用合成事件测试时用）
    func dropTest(_ edge: String) -> [String: String] {
        guard let win = window, let screen = win.screen ?? NSScreen.main else { return ["ok": "0"] }
        let vf = screen.frame
        switch edge {
        case "left":  origin = CGPoint(x: vf.minX + 4, y: vf.minY + 300)
        case "right": origin = CGPoint(x: vf.maxX - PetView.side - 4, y: vf.minY + 300)
        case "top":   origin = CGPoint(x: vf.midX - 60, y: vf.maxY - 140)
        case "nearwin":   // 靠近最前窗口的顶边
            if let w = onScreenWindows().first {
                origin = CGPoint(x: w.minX + w.maxX - w.minX / 2 - 60, y: w.top - 50)
            }
        default:      origin = CGPoint(x: vf.midX - 60, y: vf.minY + 420)
        }
        win.setFrameOrigin(origin)
        finishDrop(win: win)
        let n: String
        switch state {
        case .sitting: n = sitLie ? "lying" : "sitting"
        case .climbing(let s, let u): n = "climbing(\(s),\(u))"
        case .crawlingTop: n = "crawlingTop"
        case .falling: n = "falling"
        default: n = "other"
        }
        return ["ok": "1", "edge": edge, "state": n]
    }

    /// 松手后以球（图标）形态落地：掉落全程都是球，落地那一刻才变回小人
    private func dropAsBall() {
        fallV = 0
        if PetView.iconImage != nil {
            iconFall = true
        } else {
            iconFall = false     // 没有图标资源就退化成矢量小人下坠
        }
        state = .falling
    }

    /// 右键暂时不响应（功能菜单移到左键单击）
    override func rightMouseDown(with _: NSEvent) {
        // 走路时右键：播一次脸红动画（8帧@8fps），播完继续走；其余状态右键无效果
        guard case .walking = state, !PetView.blushFrames.isEmpty else { return }
        state = .blushing
        behaviorDuration = 1.0
        behaviorElapsed = 0
        spriteClock = 0
        phase = 0
        needsDisplay = true
    }

    override func rightMouseUp(with _: NSEvent) {}

    /// 功能菜单（左键单击后弹出）
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        let lv = NSMenuItem(title: sitOneLevelAbove
                            ? T("坐窗时置顶：开（不被遮挡）", "Stay on top when sitting: ON (never covered)")
                            : T("坐窗时置顶：关（会被前窗遮挡）", "Stay on top when sitting: OFF (can be covered)"),
                            action: #selector(toggleSitLevel), keyEquivalent: "")
        lv.target = self
        lv.state = sitOneLevelAbove ? .on : .off
        m.addItem(lv)

        // 语言：跟随系统 / 中文 / English（写进 UserDefaults，重启后仍生效）
        let langMenu = NSMenu()
        let langChoices = [("system", T("跟随系统", "Follow System")),
                           ("zh", "中文"),
                           ("en", "English")]
        for (mode, title) in langChoices {
            let it = NSMenuItem(title: title, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode
            it.state = L10n.mode == mode ? .on : .off
            langMenu.addItem(it)
        }
        let langItem = NSMenuItem(title: T("语言", "Language"), action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        m.addItem(langItem)
        m.addItem(.separator())

        let sub = NSMenu()
        let apps = PetView.scanAgents()
        if apps.isEmpty {
            let empty = NSMenuItem(title: T("未找到智能体应用", "No AI agent app found"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for (name, url) in apps {
                let it = NSMenuItem(title: name, action: #selector(launchAgent(_:)), keyEquivalent: "")
                it.representedObject = url
                it.target = self
                sub.addItem(it)
            }
        }
        let folder = NSMenuItem(title: T("打开应用程序文件夹…", "Open Applications folder…"),
                                action: #selector(openAppsFolder), keyEquivalent: "")
        folder.target = self
        sub.addItem(folder)
        let agentsItem = NSMenuItem(title: T("打开智能体", "Open AI agent"), action: nil, keyEquivalent: "")
        agentsItem.submenu = sub
        m.addItem(agentsItem)
        m.addItem(.separator())
        let idle = NSMenuItem(title: T("回待机（挂回屏幕顶）", "Back to idle (hang on top)"),
                              action: #selector(goIdle), keyEquivalent: "")
        idle.target = self
        m.addItem(idle)
        m.addItem(NSMenuItem(title: T("退出", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return m
    }

    private func showMenu(at p: NSPoint) {
        pendingMenu = nil
        buildMenu().popUp(positioning: nil, at: p, in: self)
    }

    static func scanAgents() -> [(String, URL)] {
        // 按应用名匹配
        let keys = ["chatgpt", "claude", "codex", "copilot", "cursor", "windsurf", "trae",
                    "workbuddy", "kimi", "doubao", "豆包", "通义", "qwen", "deepseek", "gemini",
                    "ollama", "cherry", "chatbox", "manus", "coze", "扣子", "元宝", "文心",
                    "星火", "minimax", "海螺", "dify", "openai", "anthropic",
                    "autoclaw", "autoglm", "zhipu", "智谱", "chatglm", "glm"]
        // 按 bundle id 匹配（名字是英文缩写、看不出来的时候兜底）
        let idKeys = ["zhipu", "autoclaw", "autoglm", "openai", "anthropic", "moonshot", "deepseek"]
        var seen = Set<String>()
        var out: [(String, URL)] = []
        let fm = FileManager.default
        for d in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for it in items.sorted() where it.hasSuffix(".app") {
                let name = (it as NSString).deletingPathExtension
                let low = name.lowercased()
                let url = URL(fileURLWithPath: d + "/" + it)
                let bid = (Bundle(url: url)?.bundleIdentifier ?? "").lowercased()
                let hit = keys.contains(where: { low.contains($0) })
                    || idKeys.contains(where: { bid.contains($0) })
                if hit, seen.insert(url.path).inserted {
                    out.append((name, url))
                }
            }
        }
        return out
    }

    @objc private func toggle() { paused.toggle(); needsDisplay = true }

    /// 暂停后"点别处"就继续（别的应用被激活、或窗口外任意点击都会走到这里）
    func resumeIfPaused() {
        guard paused else { return }
        paused = false
        needsDisplay = true
    }

    /// 装上"点别处继续"的监听：应用激活通知（无需权限，兜底）+ 全局鼠标监听（有辅助功能权限时更灵敏）
    private func installResumeWatchers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self.resumeIfPaused()
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            DispatchQueue.main.async { self?.resumeIfPaused() }
        }
    }

    @objc private func toggleSitLevel() {
        sitOneLevelAbove.toggle()
        // 切到置顶后旧遮挡裁剪矩形必须清掉（tick 不再更新它们），否则小人会被幽灵矩形裁穿
        if sitOneLevelAbove, !coverRects.isEmpty { coverRects.removeAll() }
    }

    /// 切换界面语言：菜单/气泡/顶栏立刻生效，选择持久化
    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        applyLanguage(mode)
    }

    /// mode: "system" | "zh" | "en"
    func applyLanguage(_ mode: String) {
        L10n.mode = mode
        bubbleText = nil                 // 旧语言的气泡立刻收起，下一句用新语言
        NSApp.mainMenu = makeAppMenu()   // 顶栏「关于 / 退出」也一起换
        needsDisplay = true
    }
    @objc private func goIdle() { enterIdle() }

    @objc private func launchAgent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    @objc private func openAppsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }

    override func draw(_: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        drawPet(ctx)
        // 坐窗遮挡：把"压住宿主窗口的前窗"所占区域从画布上擦掉（等价于被真实窗口盖住）。
        // 这里必须用 clear 混合，不能用 even-odd 裁剪——多个前窗重叠时 even-odd 会把重叠区
        // 重新算成"可见"，这正是"只有前一层能挡住、第二层挡不住"的原因。
        if !coverRects.isEmpty {
            ctx.setBlendMode(.clear)
            for r in coverRects {
                let i = r.intersection(bounds)
                if !i.isNull, i.width > 0, i.height > 0 { ctx.fill(i) }
            }
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()
    }

    private func drawPet(_ ctx: CGContext) {
        // 手绘贴图模式：有对应帧集的动作直接用图播，跳过下面的矢量绘制
        if case .idleBall = state, !PetView.idleFrames.isEmpty {
            drawIdleSprite(ctx)
            return
        }
        if showIconBody {
            drawIconSprite(ctx)
            return
        }
        if case .walking = state, !PetView.walkFrames.isEmpty {
            drawWalkSprite(ctx)
            return
        }
        if case .waving = state, !PetView.greetFrames.isEmpty {
            drawGreetSprite(ctx)
            return
        }
        if case .blushing = state, !PetView.blushFrames.isEmpty {
            drawBlushSprite(ctx)
            return
        }
        if case .pondering = state, !PetView.ponderFrames.isEmpty {
            drawPonderSprite(ctx)
            return
        }
        if case .climbing(let sd, _) = state, !PetView.climbFrames.isEmpty {
            drawClimbSprite(ctx, side: sd)
            return
        }
        if case .crawlingTop = state, !PetView.crawlTopFrames.isEmpty {
            drawCrawlTopSprite(ctx)
            return
        }
        if case .sitting = state, sitLie, !PetView.lieFrames.isEmpty {
            drawLieSprite(ctx)
            return
        }
        if case .sitting = state, !sitLie, !PetView.sitFrames.isEmpty {
            drawSitSprite(ctx)
            return
        }
        let s = CGFloat(sin(phase))
        var hip = CGPoint(x: 0, y: -10)
        var shoulder = CGPoint(x: 0, y: 16)
        var headC = CGPoint(x: 0, y: 30)
        var segs: [(CGPoint, CGPoint)] = []
        var frontSegs: [(CGPoint, CGPoint)] = []   // 画在头之上（"在头前"）的肢体
        occludesHead = false                        // 头部是否遮挡先画的肢体（顶挂换手时用）
        var squashY: CGFloat = 1                    // 纵向挤压/拉伸（绕脚底为支点，横向按体积守恒反向补偿）

        switch state {
        case .idleBall:
            break   // 待机走贴图绘制（draw 入口已分发）；此矢量兜底仅在资源缺失时画默认站姿
        case .walking:
            // —— 参考 Alan Becker 火柴人实际录像帧重做的步态 ——
            // 腿为三段式（髋-膝-踝），膝盖用两骨 IK 解算：支撑腿伸直当支柱撑地（脚不滑），
            // 摆动腿膝盖高抬、脚尖离地前摆；躯干前倾；手臂屈肘与对侧腿反向摆。
            let A: CGFloat = 10              // 半步长（相位 0.13/帧 × 速度 50，恰好无滑步）
            let ground: CGFloat = -38
            let thigh: CGFloat = 15, shin: CGFloat = 15
            // 髋到踝的有效距离：只比腿长(30)短一点点，支撑腿近乎伸直但永远留约 25° 屈曲，
            // 不会绷成一根棍，也不会像蹲着。调这个数：越小膝盖越弯
            let reach: CGFloat = 29.3

            func footAt(_ u: Double) -> CGPoint {
                let c = CGFloat(u.truncatingRemainder(dividingBy: 2 * .pi))
                if c < .pi {
                    let t = c / .pi          // 支撑期：脚贴地，随身体前进而相对后滑
                    return CGPoint(x: A * (1 - 2 * t), y: ground)
                } else {
                    let t = (c - .pi) / .pi  // 摆动期：轻抬前摆，膝盖自然带起
                    return CGPoint(x: A * (2 * t - 1), y: ground + 3.8 * CGFloat(sin(t * .pi)))
                }
            }
            func joint(_ root: CGPoint, _ tip: CGPoint, _ l1: CGFloat, _ l2: CGFloat, forward: Bool) -> CGPoint {
                // 两骨 IK：解出中间关节（膝或肘）。forward 决定弯向哪一侧
                let dx = tip.x - root.x, dy = tip.y - root.y
                let raw = (dx * dx + dy * dy).squareRoot()
                let d = min(max(raw, abs(l1 - l2) + 0.5), l1 + l2 - 0.5)
                let inv = raw > 0.001 ? 1 / raw : 0
                let ux = dx * inv, uy = dy * inv
                let h = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
                let k = max((l1 * l1 - h * h).squareRoot(), 0)
                let nx = forward ? -uy : uy, ny = forward ? ux : -ux
                return CGPoint(x: root.x + ux * h + nx * k, y: root.y + uy * h + ny * k)
            }

            let f0 = footAt(phase), f1 = footAt(phase + .pi)
            // 髋高 = 支撑腿像支柱一样恰好够到地面：触地时最低、经过时最高（真实重心节奏）
            let stanceX = f0.y <= ground + 0.5 ? f0.x : f1.x
            let hipY = ground + (reach * reach - min(stanceX * stanceX, reach * reach * 0.96)).squareRoot()
            let lean: CGFloat = 2
            hip = CGPoint(x: 0, y: hipY)
            shoulder = CGPoint(x: lean, y: hipY + 24)
            // 头压在肩膀正上方、略靠后一点：前倾只由躯干承担，脖子不前探（否则像驼背）
            headC = CGPoint(x: lean - 1.0, y: hipY + 33)

            let k0 = joint(hip, f0, thigh, shin, forward: true)
            let k1 = joint(hip, f1, thigh, shin, forward: true)
            segs = [
                (hip, k0), (k0, f0),
                (hip, k1), (k1, f1),
                (hip, shoulder)
            ]
            // 脚：支撑期平贴地面，摆动期脚尖略垂（放松，不做夸张的勾脚）
            for f in [f0, f1] {
                let swing = f.y - ground > 0.5
                segs.append((f, CGPoint(x: f.x + (swing ? 3 : 4.5), y: f.y + (swing ? -2.5 : 0))))
            }
            // 手臂：近乎垂下，肘只微屈（约 25°）；前摆时肘略收、后摆略伸，
            // 并且比腿滞后一点点（跟着甩，不是同步摆）
            func arm(_ u: Double) -> [(CGPoint, CGPoint)] {
                let s = CGFloat(cos(u))
                let swingA = 0.16 * s                       // 前后摆角 ±9°
                let reachArm = 27.2 - 0.6 * s               // 肩到手距离（越小肘越弯）
                let hand = CGPoint(x: shoulder.x + reachArm * sin(swingA),
                                   y: shoulder.y - reachArm * cos(swingA))
                let el = joint(shoulder, hand, 14, 14, forward: false)
                return [(shoulder, el), (el, hand)]
            }
            segs += arm(phase + .pi + 0.15) + arm(phase + 0.12)

            // 挤压与拉伸：只留一点点承重感，别像在跺地
            squashY = 1 - 0.008 * (stanceX / A)
            if landingT < 0.55 {
                squashY -= 0.05 * max(0, exp(-landingT * 9) * cos(landingT * 26))
            }
        case .climbing:
            // 侧视攀岩：身体平行墙面，四肢贴墙交替挪动（本地 -y 指向墙面）
            let press = 2.5 * CGFloat(sin(phase))
            hip = CGPoint(x: -14, y: -32 + press)
            shoulder = CGPoint(x: 12, y: -28 - press)
            headC = CGPoint(x: 25, y: -26)
            func tip(_ ax: CGFloat, _ off: Double) -> CGPoint {
                let lift = 9 * CGFloat(max(0, sin(phase + off + .pi / 2)))
                return CGPoint(x: ax + 19 * CGFloat(sin(phase + off)), y: wallY + lift)
            }
            segs = [
                (shoulder, tip(shoulder.x, 0)),
                (shoulder, tip(shoulder.x, .pi)),
                (shoulder, hip),
                (hip, tip(hip.x, .pi / 2)),
                (hip, tip(hip.x, 3 * .pi / 2))
            ]
        case .crawlingTop:
            // 倒挂悬垂：双臂交汇于头部圆圈底缘的正下方点，手举过头抓天花板线。
            // 两手左右严格交替：一只在头前、一只在头后，换手时交换位置。
            // 画在头后的那条手臂会被头部圆圈真正遮挡（裁剪掉圆内部分）。
            let hr = PetView.headR
            let g = phase * 0.55
            let cg = CGFloat(cos(g))
            let lift = CGFloat(pow(abs(sin(g)), 3))     // 抓牢时贴在顶边，换手途中才略微离墙
            let sway = 2.5 * CGFloat(sin(g))
            shoulder = CGPoint(x: sway, y: -16)         // 双臂交汇点
            hip = CGPoint(x: sway * 0.85, y: 14)
            headC = CGPoint(x: sway, y: -16 - hr)       // 头在交汇点正上方，交汇点落在圆圈底缘
            occludesHead = true
            let reach: CGFloat = 12
            let handA = CGPoint(x: shoulder.x + reach * cg, y: wallY + 5 * lift)
            let handB = CGPoint(x: shoulder.x - reach * cg, y: wallY + 2.5 * lift)
            let b1 = 0.12 + 0.10 * CGFloat(sin(phase + .pi / 2))
            let b2 = -0.12 + 0.10 * CGFloat(sin(phase + 3 * .pi / 2))
            segs = [
                (shoulder, hip),
                (hip, CGPoint(x: hip.x + L * sin(b1), y: hip.y + L * cos(b1))),
                (hip, CGPoint(x: hip.x + L * sin(b2), y: hip.y + L * cos(b2)))
            ]
            // 现在在头前（右侧）的那条手臂盖在头之上，在头后的那条被头挡住
            if cg >= 0 {
                frontSegs.append((shoulder, handA))
                segs.append((shoulder, handB))
            } else {
                frontSegs.append((shoulder, handB))
                segs.append((shoulder, handA))
            }
        case .sitting:
            // 坐在窗口顶边上睡觉：屁股在线上，腿垂在窗面，身体轻微呼吸起伏
            let breathe = 1.5 * CGFloat(sin(phase * 2))
            hip = CGPoint(x: 0, y: -14)
            shoulder = CGPoint(x: 6, y: 14 + breathe)
            headC = CGPoint(x: 9, y: 24 + breathe)
            segs = [
                (hip, CGPoint(x: 15, y: -11)),
                (CGPoint(x: 15, y: -11), CGPoint(x: 15, y: -41)),
                (hip, shoulder),
                (shoulder, CGPoint(x: 10, y: -15))
            ]
        case .pondering, .blushing:
            // 站定沉思（脸红贴图缺失时的矢量兜底同用此姿势）
            let breathe = 1.2 * CGFloat(sin(phase * 1.7))
            let sway = 1.4 * CGFloat(sin(phase * 0.55))
            hip = CGPoint(x: sway * 0.5, y: -10)
            shoulder = CGPoint(x: sway, y: 16 + breathe)
            headC = CGPoint(x: sway + 2, y: 30 + breathe)
            let elbow = CGPoint(x: sway + 14, y: 6 + breathe)
            segs = [
                (hip, CGPoint(x: -9, y: -38)),
                (hip, CGPoint(x: 9, y: -38)),
                (hip, shoulder),
                (shoulder, CGPoint(x: sway - 12, y: -6)),          // 垂着的手臂
                (shoulder, elbow),
                (elbow, CGPoint(x: sway + 7, y: 21 + breathe))     // 前臂托住下巴
            ]
        case .waving:
            // 停下挥手打招呼：先下蹲蓄力（预备动作）再原地蹦跳，落地有挤压
            let t = behaviorElapsed
            let crouch = t < 0.45 ? -7 * CGFloat(sin(min(t / 0.45, 1) * .pi / 2)) : 0
            let jump = max(0, CGFloat(sin(phase * 0.75))) * 13
            let dy = crouch + jump
            let ang = 0.95 + 0.22 * CGFloat(sin(phase * 1.35))
            hip = CGPoint(x: 0, y: -10 + dy)
            shoulder = CGPoint(x: 0, y: 16 + dy)
            headC = CGPoint(x: 0, y: 30 + dy * 0.85)     // 头略滞后于身体
            squashY = 1 + crouch * 0.011 + 0.04 * (jump / 13)   // 蹲下压扁、起跳拉长
            let hand = CGPoint(x: shoulder.x + 27 * sin(ang), y: shoulder.y + 27 * cos(ang))
            let footY = -38 + jump                        // 下蹲时脚不离地，腿自己缩短（曲膝）
            segs = [
                (hip, CGPoint(x: -8, y: footY)),
                (hip, CGPoint(x: 8, y: footY)),
                (hip, shoulder),
                (shoulder, CGPoint(x: -13, y: -7 + dy)),                // 另一只手垂着
                (shoulder, hand)
            ]
        case .falling, .dragged:
            let sway = 0.2 * s
            if case .falling = state { squashY = 1.05 }   // 下坠时沿运动方向拉长（体积不变所以变窄）
            segs = [
                (shoulder, CGPoint(x: shoulder.x + L * sin(0.55), y: shoulder.y + L * cos(0.55))),
                (shoulder, CGPoint(x: shoulder.x - L * sin(0.55), y: shoulder.y + L * cos(0.55))),
                (shoulder, hip),
                (hip, CGPoint(x: hip.x + L * sin(0.3 + sway), y: hip.y - L * cos(0.3 + sway))),
                (hip, CGPoint(x: hip.x - L * sin(0.3 - sway), y: hip.y - L * cos(0.3 - sway)))
            ]
        }

        var flipX = false
        if case .walking(let wd) = state { flipX = wd == -1 }   // 朝向：膝/肘/前倾都朝行进方向
        if case .climbing(let sd, let up) = state { flipX = up != (sd == 1) }
        lastHeadC = headC   // 给气泡定位用（尾巴要指向头中心）
        lastSquashY = squashY

        // 把刚性线段转成带弯曲的柔软肢体
        let limbs = makeLimbs(segs, prev: &prevMain, prevBend: &prevMainBend, idBase: 0)
        let frontLimbs = makeLimbs(frontSegs, prev: &prevFront, prevBend: &prevFrontBend, idBase: 3.1)

        ctx.saveGState()
        ctx.translateBy(x: c, y: c)
        ctx.rotate(by: theta)
        if flipX { ctx.scaleBy(x: -1, y: 1) }
        if abs(squashY - 1) > 0.0008 {
            // 绕脚底支点做纵向形变，横向按 1/√s 补偿，保持体积恒定
            let pivotY: CGFloat = -40
            ctx.translateBy(x: 0, y: pivotY)
            ctx.scaleBy(x: 1 / squashY.squareRoot(), y: squashY)
            ctx.translateBy(x: 0, y: -pivotY)
        }

        if occludesHead {
            // 头部是个实心遮挡体：把圆内的肢体裁掉，形成"从头的后面穿过"的效果
            let hr = PetView.headR
            ctx.saveGState()
            let clip = CGMutablePath()
            clip.addRect(CGRect(x: -300, y: -300, width: 600, height: 600))
            clip.addEllipse(in: CGRect(x: headC.x - hr, y: headC.y - hr, width: hr * 2, height: hr * 2))
            ctx.addPath(clip)
            ctx.clip(using: .evenOdd)
            drawSegs(limbs)
            ctx.restoreGState()
        } else {
            drawSegs(limbs)
        }

        let hr = PetView.headR
        let head = handHead(CGPoint(x: headC.x, y: headC.y), hr)
        head.lineWidth = 7.5; head.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke(); head.stroke()
        head.lineWidth = 3.6; NSColor.black.setStroke(); head.stroke()

        if case .sitting = state {
            let t1 = CGFloat((phase / (2 * .pi)).truncatingRemainder(dividingBy: 1))
            drawZ(CGPoint(x: headC.x + 10 + 8 * t1, y: headC.y + 14 + 16 * t1), size: 11, alpha: max(0, 1 - t1))
            let t2 = CGFloat((phase / (2 * .pi) + 0.5).truncatingRemainder(dividingBy: 1))
            drawZ(CGPoint(x: headC.x + 8 + 8 * t2, y: headC.y + 12 + 16 * t2), size: 9, alpha: max(0, 0.8 * (1 - t2)))
        }
        if case .pondering = state {
            let a = 0.30 + 0.45 * CGFloat(0.5 + 0.5 * sin(phase * 0.9))
            drawGlyph("?", CGPoint(x: headC.x + 13, y: headC.y + 7 + 3 * CGFloat(sin(phase * 0.7))), size: 14, alpha: a)
        }

        if !frontSegs.isEmpty { drawSegs(frontLimbs) }

        ctx.restoreGState()
    }

    /// 拖动中 / 双击掉落中：显示球图标
    private var showIconBody: Bool {
        guard PetView.iconImage != nil else { return false }
        if case .dragged = state { return true }
        if case .falling = state, iconFall { return true }
        return false
    }

    /// 播手绘行走帧：240 画布按 1/2 缩到 120 视口（与 ponder 同管线，头径严格一致），8fps
    private func drawWalkSprite(_ ctx: CGContext) {
        let fs = PetView.walkFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        // 头心：画布 (128.5, 66) → 视图 (4.25, 87)，相对窗口中心 c(60,60)
        lastHeadC = CGPoint(x: 128.5 * 0.5 - 60, y: 120 - 66 * 0.5 - 60)
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // 素材朝右；向左走整帧水平镜像（AppKit 非 flipped 视图，CGImage 直接画为正像）
        if walkDir == -1 {
            ctx.translateBy(x: PetView.side, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 0, width: PetView.side, height: PetView.side))
        ctx.restoreGState()
    }

    /// 播手绘打招呼帧：240×280 画布按 1/2 缩到 120×140 视口，8fps。
    /// 窗口此时临时加高到 160（tick 里做），绘制矩形 y 偏移 1pt 使脚底（画布238）落在地面接触线
    private func drawGreetSprite(_ ctx: CGContext) {
        let fs = PetView.greetFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        // 站姿头心画布 (122.4, 91.6)（280高、y从顶算）→ 视图 x=61.2、y=1+(280-91.6)/2=95.2
        lastHeadC = CGPoint(x: 122.4 * 0.5 - 60, y: 1 + (280 - 91.6) * 0.5 - 60)
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 1, width: PetView.side, height: 140))
        ctx.restoreGState()
    }

    /// 播手绘脸红帧：240 画布按 1/2 缩到 120 视口（与 walk 同管线），8fps 播一次
    private func drawBlushSprite(_ ctx: CGContext) {
        let fs = PetView.blushFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        // 站姿头心画布 (111.7, 51.0)（y从顶算）→ 视图 (55.85, 120-25.5)
        lastHeadC = CGPoint(x: 111.7 * 0.5 - 60, y: 120 - 51.0 * 0.5 - 60)
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 0, width: PetView.side, height: PetView.side))
        ctx.restoreGState()
    }

    /// 待机球：绳拴屏幕顶边（画布顶=窗口顶=屏幕顶），球在下方甩圈，8fps。
    /// 画布 240 → 1/3 绘制 80pt（球径 61px→20.3pt 与爬行一致），挂点=画布(120,0)=窗口顶部中心
    private func drawIdleSprite(_ ctx: CGContext) {
        let fs = PetView.idleFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        lastHeadC = CGPoint(x: 0, y: 0)      // 待机无气泡，仅占位
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        let s: CGFloat = 80                   // 画布240 → 1/3 缩放 = 80pt 视口（球径20.3pt与爬行一致）
        ctx.draw(fs[idx], in: CGRect(x: (PetView.side - s) / 2, y: PetView.side - s,
                                     width: s, height: s))
        ctx.restoreGState()
    }

    /// 拖动 / 双击掉落时的球图标：球径与爬行球严格一致（iconSide 已按球径换算）
    private func drawIconSprite(_ ctx: CGContext) {
        guard let icon = PetView.iconImage else { return }
        lastHeadC = CGPoint(x: 0, y: 0)
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        let s = PetView.iconSide
        let o = (PetView.side - s) / 2
        ctx.draw(icon, in: CGRect(x: o, y: o, width: s, height: s))
        ctx.restoreGState()
    }

    /// 播手绘沉思帧：240 画布按 1/2 缩到 120 视口，脚底正好落在 y=22（与矢量小人一致）
    private func drawPonderSprite(_ ctx: CGContext) {
        let fs = PetView.ponderFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        lastHeadC = CGPoint(x: 0, y: 34)   // 气泡尾巴指向头部中心
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // AppKit 非 flipped 视图 y 向上，CGImage 直接画即为正像，不能再翻转
        if walkDir == -1 {
            ctx.translateBy(x: PetView.side, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 0, width: PetView.side, height: PetView.side))
        ctx.restoreGState()
    }

    /// 播手绘贴边爬行帧：右侧例图原样（触须端=画布右缘=屏幕边），左侧整帧水平镜像。
    /// 按 climbScale 缩小绘制、右对齐（缩了也贴边）、垂直居中；
    /// 头心来自 climb_prep.py 的逐帧实测并按同一缩放映射，气泡尾巴照旧指向头心。
    private func drawClimbSprite(_ ctx: CGContext, side: Int) {
        let fs = PetView.climbFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        let sc = PetView.climbScale
        let s = PetView.side * sc                    // 120 × 2/3 = 80
        let k = s / 240                              // 画布240 → 视图80 的映射系数 = 1/3
        let ox = PetView.side - s                    // 右对齐：画布右缘(触须端)仍在屏幕边
        let oy = (PetView.side - s) / 2              // 垂直居中
        let hc = PetView.climbHeadPts[min(idx, PetView.climbHeadPts.count - 1)]
        var hx = ox + hc.x * k                       // 画布 x → 视图 x（必须用 k，不是 sc！）
        let hy = oy + s - hc.y * k                   // 画布 y(从顶) → 视图 y(向上)
        if side == -1 { hx = PetView.side - hx }     // 左缘镜像：头心跟着翻到窗口右半
        lastHeadC = CGPoint(x: hx - c, y: hy - c)
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        if side == -1 {
            ctx.translateBy(x: PetView.side, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.draw(fs[idx], in: CGRect(x: ox, y: oy, width: s, height: s))
        ctx.restoreGState()
    }

    /// 播手绘顶边攀行帧：240 画布 × 1/2 = 整窗 120pt，画布 y=0（双手最高点）=窗口顶=屏幕顶边。
    /// 素材视为向右攀行，dir==-1 整帧水平镜像（头心 x 同步取反）。8fps。
    private func drawCrawlTopSprite(_ ctx: CGContext) {
        let fs = PetView.crawlTopFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        let hc = PetView.crawlTopHeadPts[min(idx, PetView.crawlTopHeadPts.count - 1)]
        var hx = hc.x * 0.5                    // 画布 x → 视图 x（×0.5）
        let hy = PetView.side - hc.y * 0.5     // 画布 y(从顶) → 视图 y(向上)
        var mirrored = false
        if case .crawlingTop(let d) = state, d == -1 { mirrored = true }
        if mirrored { hx = PetView.side - hx }
        lastHeadC = CGPoint(x: hx - c, y: hy - c)
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        if mirrored {
            ctx.translateBy(x: PetView.side, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 0, width: PetView.side, height: PetView.side))
        ctx.restoreGState()
    }

    /// 播手绘坐姿帧：画布 240×264 × 1/2 → 视口 120×132（窗口临时加高 132，tick 里做），
    /// 接触线（屁股+双手水平线）画布 y=148 → 视图 y=58 = 宿主窗口顶边。8fps。
    /// 头心由 prep 逐帧模板匹配导出（视图坐标、相对窗口中心、y 向上），theta 恒 0
    private func drawSitSprite(_ ctx: CGContext) {
        let fs = PetView.sitFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        lastHeadC = PetView.sitHeadPts[min(idx, PetView.sitHeadPts.count - 1)]
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 0, width: PetView.side, height: 132))
        ctx.restoreGState()
    }

    /// 播手绘躺姿帧：画布 240×240 × 1/2 整窗，身体直线（画布 y=148）→ 视图 46 = 宿主窗口顶边。
    /// 素材头朝左固定不镜像（躺姿与行走方向无关）；头左上方小圆是睡觉泡泡装饰，头心由
    /// prep 模板匹配标定（泡泡是孤立连通域，已剔除，不会误指）。8fps
    private func drawLieSprite(_ ctx: CGContext) {
        let fs = PetView.lieFrames
        guard !fs.isEmpty else { return }
        let idx = min(fs.count - 1, Int(max(0, spriteClock) * 8) % fs.count)
        lastHeadC = PetView.lieHeadPts[min(idx, PetView.lieHeadPts.count - 1)]
        lastSquashY = 1
        occludesHead = false
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(fs[idx], in: CGRect(x: 0, y: 0, width: PetView.side, height: PetView.side))
        ctx.restoreGState()
    }

    /// 把线段算成柔软曲线：弯曲量 = 呼吸般的微弯 + 末端相对摆动速度带来的惯性滞后。
    /// 摆得越快弯得越明显、且弯向运动的反侧（像被空气拖住），停下时自然回正。
    private func makeLimbs(_ raw: [(CGPoint, CGPoint)],
                           prev: inout [(CGPoint, CGPoint)],
                           prevBend: inout [CGFloat],
                           idBase: Double) -> [Limb] {
        var out: [Limb] = []
        out.reserveCapacity(raw.count)
        for (i, seg) in raw.enumerated() {
            let dx = seg.1.x - seg.0.x
            let dy = seg.1.y - seg.0.y
            let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let ux = dx / len, uy = dy / len

            // 静止时也有极轻微的弧度（呼吸相位错开），不至于像木棍
            var bend = 0.7 * CGFloat(sin(phase * 0.8 + idBase + Double(i) * 1.9))

            if i < prev.count {
                // 肢体末梢相对根部的位移 = 这一帧肢体真正的"甩动"量
                let p = prev[i]
                let vx = (seg.1.x - seg.0.x) - (p.1.x - p.0.x)
                let vy = (seg.1.y - seg.0.y) - (p.1.y - p.0.y)
                // 垂直于肢体的速度分量：正向甩动使肢体向后弯
                let side = -uy * vx + ux * vy
                bend += max(-3.0, min(3.0, -side * 0.45))
            }
            // 一阶低通，避免逐帧抖动
            if i < prevBend.count { bend = prevBend[i] * 0.32 + bend * 0.68 }

            out.append(Limb(a: seg.0, b: seg.1, bend: bend))
        }
        prev = raw
        prevBend = out.map { $0.bend }
        return out
    }

    /// 手绘噪声：确定性（同一输入永远同输出），线条形状稳定不会逐帧闪烁
    private func hnoise(_ u: Double, _ seed: Double) -> CGFloat {
        let v = sin(u * 91.7 + seed * 37.3) * cos(u * 47.9 + seed * 11.1) * 43758.5453
        return CGFloat(v - v.rounded(.down) - 0.5)
    }

    /// 手绘风格描边：沿曲线采样 → 微抖 → 两端略出头 → 逐段笔压变宽
    /// （模仿用户的画：线条粗、边缘有呼吸感、关节处自然溢出）
    private func drawSegs(_ list: [Limb]) {
        guard !list.isEmpty else { return }
        func samples(_ s: Limb) -> [CGPoint] {
            let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
            let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let nx = -dy / len, ny = dx / len
            let mid = CGPoint(x: (s.a.x + s.b.x) / 2, y: (s.a.y + s.b.y) / 2)
            let ctrl = CGPoint(x: mid.x + nx * s.bend * 2, y: mid.y + ny * s.bend * 2)
            // 两端沿走向各溢出一点，像手绘线条在关节处自然出头
            let ux = dx / len, uy = dy / len
            let a = CGPoint(x: s.a.x - ux * 1.3, y: s.a.y - uy * 1.3)
            let b = CGPoint(x: s.b.x + ux * 1.3, y: s.b.y + uy * 1.3)
            let seed = Double(abs(s.bend)) * 3.1
            let N = 9
            var pts: [CGPoint] = []
            for i in 0...N {
                let t = CGFloat(i) / CGFloat(N)
                let mt = 1 - t
                // 二次贝塞尔采样
                let x = mt * mt * a.x + 2 * mt * t * ctrl.x + t * t * b.x
                let y = mt * mt * a.y + 2 * mt * t * ctrl.y + t * t * b.y
                // 抖动幅度：端点为 0（保证关节衔接），中段最大
                let amp = 0.55 * CGFloat(sin(Double(t) * .pi))
                let off = hnoise(Double(i) * 0.73 + seed, 5.5)
                pts.append(CGPoint(x: x + nx * off * amp, y: y + ny * off * amp))
            }
            return pts
        }
        for pass in [(NSColor.white.withAlphaComponent(0.9), CGFloat(8.4)), (NSColor.black, CGFloat(4))] {
            pass.0.setStroke()
            for s in list {
                let pts = samples(s)
                for i in 0..<(pts.count - 1) {
                    let t = Double(i) / Double(pts.count - 1)
                    let wobble = 1 + 0.13 * hnoise(t * 3.7 + Double(abs(s.bend)), 9.2)   // 笔压不匀
                    let p = NSBezierPath()
                    p.move(to: pts[i])
                    p.line(to: pts[i + 1])
                    p.lineWidth = pass.1 * CGFloat(wobble)
                    p.lineCapStyle = .round
                    p.stroke()
                }
            }
        }
    }

    /// 手绘风格的头：圆上叠一点低频椭圆歪斜 + 细噪声，像手画出来的圆
    private func handHead(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineJoinStyle = .round
        let n = 16
        var pts: [CGPoint] = []
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            // 低频：整体略椭圆（歪向一个固定方向）；高频：细小手抖
            let wobble = 0.055 * sin(2 * a + 0.9) + 0.035 * hnoise(Double(i) * 1.31, 3.3)
            let rr = r * (1 + wobble)
            pts.append(CGPoint(x: c.x + rr * cos(a), y: c.y + rr * sin(a)))
        }
        p.move(to: pts[0])
        for i in 1...n { p.line(to: pts[i % n]) }
        p.close()
        return p
    }

    private func drawGlyph(_ text: String, _ p: CGPoint, size: CGFloat, alpha: CGFloat) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        (text as NSString).draw(at: p, withAttributes: attr)
    }

    private func drawZ(_ p: CGPoint, size: CGFloat, alpha: CGFloat) {
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(alpha)
        ]
        ("z" as NSString).draw(at: p, withAttributes: attr)
    }
}

/// 正式软件形态：Dock 常驻（双击启动、Dock 右键有"退出"），桌宠面板本身仍不抢焦点
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var pet: PetView?
    /// 程序坞右键菜单：回待机 + 退出（系统默认还会附赠"显示/隐藏"）
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let idle = NSMenuItem(title: T("回待机（挂回屏幕顶）", "Back to idle (hang on top)"),
                              action: #selector(dockIdle), keyEquivalent: "")
        idle.target = self
        m.addItem(idle)
        m.addItem(NSMenuItem(title: T("退出 MONO", "Quit MONO"),
                             action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        return m
    }
    @objc private func dockIdle() { pet?.enterIdle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return true   // 双击 Dock 图标不报"无法重新打开"
    }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true   // 消除 macOS 启动日志里的 Secure coding 警告
    }
    func applicationWillTerminate(_ notification: Notification) {
        pet?.shutdown()   // ⌘Q / Dock 退出：顺手删掉控制总线的 socket 文件
    }
}

/// 顶栏应用菜单（⌘Q 退出）：语言切换后要重建，所以抽成函数
func makeAppMenu() -> NSMenu {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu(title: "MONO")
    appMenu.addItem(NSMenuItem(title: T("关于 MONO", "About MONO"),
                               action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: T("退出 MONO", "Quit MONO"),
                               action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu
    mainMenu.addItem(appItem)
    return mainMenu
}

let app = NSApplication.shared

// 单实例守卫①：同 bundle id 已有实例在跑就静默退出。
//（macOS 允许同一应用从不同路径各启一份——解压目录里的 MONO.app 和"应用程序"里的
//  MONO.app 先后打开就会出现两个小人；LaunchServices 只在"同一路径"时帮你去重）
let myBid = Bundle.main.bundleIdentifier ?? "io.github.hotpeter.mono"
if NSWorkspace.shared.runningApplications.contains(where: {
    $0.bundleIdentifier == myBid && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
}) {
    exit(0)
}
app.setActivationPolicy(.regular)   // 常规应用：进 Dock、可双击启动、右键可退出

let S = PetView.side
let vf = (NSScreen.main ?? NSScreen.screens[0]).frame
let startOrigin = CGPoint(x: vf.midX - S / 2, y: vf.minY - 16)

let panel = NSPanel(contentRect: NSRect(origin: startOrigin, size: NSSize(width: S, height: S)),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
panel.level = .statusBar  // 高于程序坞层级，走在 Dock 上也可见
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = false
panel.isMovable = false
panel.ignoresMouseEvents = false
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

let view = PetView(frame: NSRect(x: 0, y: 0, width: S, height: S))
panel.contentView = view
view.start(at: startOrigin)
view.enterIdle()    // 默认状态：待机球挂在屏幕顶边左上角
if let iconPath = Bundle.main.resourceURL?.appendingPathComponent("icon.png"),
   let icon = NSImage(contentsOf: iconPath) {
    NSApp.applicationIconImage = icon   // 用户手绘球同时作为 App 图标
}

// 菜单栏与 Dock 右键：给正式软件一个最小可用的应用菜单（⌘Q 退出）
let appDelegate = AppDelegate()
appDelegate.pet = view
app.delegate = appDelegate
app.mainMenu = makeAppMenu()

panel.orderFrontRegardless()
app.run()
