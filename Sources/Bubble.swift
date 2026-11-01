import AppKit

/// 手绘气泡（用户的画）：独立透明小窗，点击穿透，贴图不可变形。
/// 贴图来自 Resources/bubble/bubble1~3.png，尾巴尖位置人工标定为归一化坐标（y 从顶部算）。
final class BubbleWindow: NSPanel {
    let view = BubbleView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 96),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = view
    }

    /// 传入屏幕坐标的遮挡矩形。只存屏幕坐标，绘制那一刻才换算成窗口内坐标：
    /// 气泡会一直跟着头部平滑移动，若在设置时就算死，擦除的洞会跟着气泡一起漂走，
    /// 前窗边缘就会漏出一条气泡。
    func setOccluders(screenRects: [CGRect]) {
        view.occluderScreenRects = screenRects
    }

    /// 气泡移动时重画（洞必须始终对齐屏幕上那个前窗）
    override func setFrameOrigin(_ point: NSPoint) {
        let moved = point != frame.origin
        super.setFrameOrigin(point)
        if moved, !view.occluderScreenRects.isEmpty { view.needsDisplay = true }
    }
}

struct BubbleAsset {
    let image: NSImage
    let tip: CGPoint       // 尾巴尖端锚点（归一化，y 从顶部算）
    let tangent: CGPoint   // 尖端切线 = 弧线远离气泡那一端的行进方向（图内 y 向下）
    let mask: [Bool]       // 降采样 alpha 蒙版（实心像素=true），用于精确遮挡判定
    static let maskN = 96  // 96x96：48 时细尾巴笔画会被降采样抹掉，导致"尾巴盖头"检测失明
}

final class BubbleView: NSView {
    static let bubbles: [BubbleAsset] = loadBubbles()

    static func loadBubbles() -> [BubbleAsset] {
        // (尖端锚点, 尖端切线外指方向) —— 2026-10-30 放大网格实测重标：
        // b1 左上尖角汇合点，朝左上；b2 Z形折尾游离端在底部(762,285)/887x290，末端朝下偏右；
        // b3 长弧尾游离端在(478,353)/978x356，末端切线朝下偏右（旧标定水平分量反了）
        let tails: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 0.005, y: 0.010), CGPoint(x: -0.34, y: -0.94)),  // b1 左上尖角，朝左上
            (CGPoint(x: 0.859, y: 0.983), CGPoint(x: 0.23, y: 0.97)),    // b2 Z形折尾，游离端朝下偏右
            (CGPoint(x: 0.489, y: 0.992), CGPoint(x: 0.26, y: 0.97)),    // b3 长弧尾，游离端朝下偏右
        ]
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("bubble"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [BubbleAsset] = []
        for f in names.filter({ $0.lowercased().hasSuffix(".png") }).sorted() {
            guard let img = NSImage(contentsOf: dir.appendingPathComponent(f)),
                  let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            let idx = out.count < tails.count ? out.count : 0
            out.append(BubbleAsset(image: img, tip: tails[idx].0, tangent: tails[idx].1,
                                   mask: Self.alphaMask(cg)))
        }
        return out
    }

    /// 把贴图渲染成 96x96 的 alpha 布尔蒙版
    private static func alphaMask(_ cg: CGImage) -> [Bool] {
        let n = BubbleAsset.maskN
        var buf = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &buf, width: n, height: n, bitsPerComponent: 8,
                                  bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return [Bool](repeating: true, count: n * n)   // 失败时保守当作全实心
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        // 阈值 55：细笔画降采样后 alpha 会被稀释，取低阈值才拦得住"尾巴扫过头"
        return (0..<n * n).map { buf[$0 * 4 + 3] > 55 }
    }

    var text: String? { didSet { needsDisplay = true } }
    var textKey: String?
    var alpha: CGFloat = 0 { didSet { needsDisplay = true } }
    var index = 0                       // 用哪张气泡
    var flipX = false { didSet { needsDisplay = true } }   // 水平镜像（尾巴换边）
    var flipY = false { didSet { needsDisplay = true } }   // 垂直翻转（尾巴朝上/朝下）

    var scale: CGFloat = 0.2    // 贴图 uniform 缩放，setScaled 尺寸后固定，移动中形状不变

    /// 根据文字长度定 uniform 缩放（含上下限），返回窗口尺寸
    /// scaleMul：外部按可用空间给的额外收缩系数（贴屏顶时缩小气泡避免遮人）
    func fitSize(for text: String, scaleMul: CGFloat = 1) -> NSSize {
        guard !Self.bubbles.isEmpty else { return NSSize(width: 120, height: 40) }
        let img = Self.bubbles[index].image.size
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium)
        ]
        let ts = (text as NSString).size(withAttributes: attr)
        // 主体约占全图 78%（尾巴占一角），留出呼吸边
        let needW = ts.width + 74, needH = ts.height + 52
        var s = max(needW / img.width, needH / img.height)
        s = min(max(s, 0.13), 0.42) * scaleMul
        s = min(max(s, 0.10), 0.42)
        s *= 0.75                                    // 用户定：全部气泡缩到 3/4（尾巴间隔/方向不变）
        scale = s
        return NSSize(width: img.width * s, height: img.height * s)
    }

    /// 当前贴图内尾巴尖换算到窗口坐标（AppKit y 向上；考虑水平/垂直翻转）
    var tailPoint: CGPoint {
        guard !Self.bubbles.isEmpty else { return CGPoint(x: 60, y: 0) }
        let a = Self.bubbles[index]
        let w = a.image.size.width * scale, h = a.image.size.height * scale
        let nx = flipX ? (1 - a.tip.x) : a.tip.x
        let ny = flipY ? (1 - a.tip.y) : a.tip.y
        return CGPoint(x: nx * w, y: (1 - ny) * h)
    }

    /// 尾巴尖端切线的外指方向（AppKit 坐标 y 向上，考虑翻转）
    /// 语义：沿尾巴从气泡行进到尖端后"继续向前"的方向——头应当在这个方向上
    func tailDir() -> CGPoint {
        guard !Self.bubbles.isEmpty else { return CGPoint(x: 0, y: 1) }
        let a = Self.bubbles[index]
        let dx = flipX ? -a.tangent.x : a.tangent.x
        let dy = flipY ? -a.tangent.y : a.tangent.y
        return CGPoint(x: dx, y: -dy)   // 图内 y 向下 → AppKit y 向上
    }

    /// 当前贴图实际显示尺寸（= fitSize 的结果；不依赖窗口 bounds，评估多张气泡时不滞后）
    private var drawnSize: CGSize {
        guard !Self.bubbles.isEmpty else { return bounds.size }
        let s = Self.bubbles[index].image.size
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    /// 窗口内某点是否落在气泡实心像素上（考虑翻转）——精确遮挡判定
    /// 注意：点在贴图范围外必须直接判 false。否则 clamp 会把"头在气泡外面"
    /// 映射到蒙版最边上那一列/行，那一列恰好是实心时就会误判成"盖住头"（10 万分否决）。
    func bodyContains(_ p: CGPoint) -> Bool {
        guard !Self.bubbles.isEmpty, drawnSize.width > 1, drawnSize.height > 1,
              p.x.isFinite, p.y.isFinite,
              p.x >= 0, p.x <= drawnSize.width,
              p.y >= 0, p.y <= drawnSize.height else { return false }
        let a = Self.bubbles[index]
        let nx = p.x / drawnSize.width
        let nyTop = 1 - p.y / drawnSize.height
        let ix = flipX ? (1 - nx) : nx
        let iy = flipY ? (1 - nyTop) : nyTop
        let n = BubbleAsset.maskN
        let gx = min(n - 1, max(0, Int(ix * CGFloat(n))))
        let gy = min(n - 1, max(0, Int(iy * CGFloat(n))))
        return a.mask[gy * n + gx]
    }

    /// 窗口内某矩形是否碰到气泡实心像素（考虑翻转）
    func bodyIntersects(_ rect: CGRect) -> Bool {
        guard !Self.bubbles.isEmpty, drawnSize.width > 1, drawnSize.height > 1,
              rect.width.isFinite, rect.height.isFinite else { return false }
        // 先裁进贴图范围：矩形在气泡外的部分不能算相交（否则贴边身形永远"碰"到气泡）
        let rect = rect.intersection(CGRect(x: 0, y: 0, width: drawnSize.width, height: drawnSize.height))
        guard !rect.isNull else { return false }
        let n = BubbleAsset.maskN
        let a = Self.bubbles[index]
        // 归一化矩形（y 转为从顶部算），再按翻转还原到图内坐标
        var r0x = rect.minX / drawnSize.width, r1x = rect.maxX / drawnSize.width
        var r0y = 1 - rect.maxY / drawnSize.height, r1y = 1 - rect.minY / drawnSize.height
        // 镜像必须一次性交换，不能先改 r0x 再用改过的 r0x 算 r1x
        // （旧写法 [0.6,0.8] 会算成 [0.2,0.8]，判定区域被放大 → 翻转候选被误罚"碰身形"）
        if flipX { let t = 1 - r1x; r1x = 1 - r0x; r0x = t }
        if flipY { let t = 1 - r1y; r1y = 1 - r0y; r0y = t }
        let gx0 = min(n - 1, max(0, Int(r0x * CGFloat(n))))
        let gx1 = min(n - 1, max(0, Int(r1x * CGFloat(n))))
        let gy0 = min(n - 1, max(0, Int(r0y * CGFloat(n))))
        let gy1 = min(n - 1, max(0, Int(r1y * CGFloat(n))))
        guard gx0 <= gx1, gy0 <= gy1 else { return false }
        for gy in gy0...gy1 {
            for gx in gx0...gx1 {
                if a.mask[gy * n + gx] { return true }
            }
        }
        return false
    }

    /// 需要挖掉的区域（视图局部坐标）。坐窗时压在小人前面的窗口，必须同样压住气泡，
    /// 否则会出现"人被窗挡住、话还浮在最上层"的错层（气泡与小人共用一套遮挡）。
    /// 屏幕坐标下需要挖掉的区域。绘制时才换算成窗口内坐标（气泡窗非 flipped，y 轴与屏幕一致）
    var occluderScreenRects: [CGRect] = [] {
        didSet { if occluderScreenRects != oldValue { needsDisplay = true } }
    }

    private var occluders: [CGRect] {
        guard let o = window?.frame.origin else { return [] }
        return occluderScreenRects.map { $0.offsetBy(dx: -o.x, dy: -o.y) }
    }

    override func draw(_: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let text = text, alpha > 0.01 else { return }
        ctx.saveGState()
        drawBubbleContent(ctx, text: text)
        // 坐窗遮挡：把"压住宿主窗口的前窗"所占区域从画布上擦掉（等价于被真实窗口盖住）。
        // 必须和小人用同一招——clear 混合逐块擦，不能用 even-odd 裁剪：
        // 多个前窗重叠时 even-odd 会把重叠区重新算成"可见"，表现就是"第二层窗口挡不住"。
        if !occluders.isEmpty {
            ctx.setAlpha(1)
            ctx.setBlendMode(.clear)
            for r in occluders {
                let i = r.intersection(bounds)
                if !i.isNull, i.width > 0, i.height > 0 { ctx.fill(i) }
            }
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()
    }

    private func drawBubbleContent(_ ctx: CGContext, text: String) {
        guard !Self.bubbles.isEmpty else {
            // 兜底：没有资源时退回白色圆角矩形
            NSColor.white.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 10, dy: 14), xRadius: 12, yRadius: 12).fill()
            return
        }
        let img = Self.bubbles[index].image

        ctx.setAlpha(Double(alpha))
        ctx.saveGState()
        // 镜像只作用于贴图，文字单独画，永远正向可读
        if flipY {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        if flipX {
            ctx.translateBy(x: bounds.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        img.draw(in: bounds)
        ctx.restoreGState()

        // 文字：画在贴图中心、向"背离尾巴"的方向略偏，避开尾巴占位；
        // 字号随贴图缩放联动（气泡缩到 3/4 后固定 12pt 会溢出），限制在 9–12pt
        let fontSize = max(9, min(12, scale * 80))
        let attr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let ts = (text as NSString).size(withAttributes: attr)
        var cx = bounds.midX - ts.width / 2
        var cy = bounds.midY - ts.height / 2
        let tail = tailPoint
        let away = CGPoint(x: bounds.midX - tail.x, y: bounds.midY - tail.y)
        let len = max(1, hypot(away.x, away.y))
        cx += away.x / len * 6
        cy += away.y / len * 6
        (text as NSString).draw(at: CGPoint(x: cx, y: cy), withAttributes: attr)
    }
}
