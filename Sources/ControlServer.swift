import Foundation

/// 本地控制总线：Unix domain socket，纯文本单行协议，无网络端口、无防火墙弹窗。
///
/// 用法（终端或任何脚本）：
///   echo "say 今天网速有点慢" | nc -U /tmp/stickman.sock
///   echo "do wave" | nc -U /tmp/stickman.sock
///   echo "state" | nc -U /tmp/stickman.sock
///
/// 协议：<命令> <参数...>，命令与参数以空格分隔，文本类参数取行内剩余全部内容。
///   say   <文本>            让它说一句话（气泡 5 秒）
///   sayf  <秒> <文本>       自定义时长
///   do    <动作> [秒]       walk / ponder / wave / sit / stand / top / left / right
///   face  <left|right>      转向
///   mute / unmute           开关自动气泡（不影响手动 say）
///   state                   查询当前状态
/// 控制总线的启动结果。
///
/// 必须区分"已有活实例"和"路径不可用"：前者说明用户重复打开了 App，应当静默退出；
/// 后者只是调试接口没起来，桌宠本身完全能跑，绝不能因此让主程序退出。
enum ControlServerStartResult {
    case ok                 // 已成功监听
    case anotherInstance    // 同一个用户的另一个实例正在监听 → 调用方应退出自己
    case unavailable        // 所有候选路径都不可用（权限/占用）→ 没有调试接口，但继续运行
}

final class ControlServer {
    private let candidates: [String]
    /// 实际监听的路径（成功启动后才有值；调试接口查询/脚本要用它）
    private(set) var path: String = ""
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "stickman.control", qos: .utility)
    private var handler: (([String]) -> [String: String])?

    /// 默认候选路径：
    ///   1. /tmp/stickman.sock —— 固定名，README 和所有脚本都按它写；
    ///   2. /tmp/stickman-<uid>.sock —— 退路。
    ///
    /// 为什么要退路：/tmp 带 sticky bit，只允许文件**属主**删除。同一台 Mac 上换另一个
    /// macOS 用户登录、而前一个用户留下了残留 socket 时，我们既连不上（0600）也删不掉
    /// （EPERM）。此时用按 uid 区分的路径，多用户各跑各的，互不干扰。
    static var defaultPaths: [String] {
        ["/tmp/stickman.sock", "/tmp/stickman-\(getuid()).sock"]
    }

    init(paths: [String]) {
        self.candidates = paths
    }

    convenience init(path: String) {
        self.init(paths: [path])
    }

    /// 探测 socket 后面是否有活实例在监听：能连上 = 有（连上即关，空连接对端无害）
    private func socketAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        return r == 0
    }

    /// 在一条具体路径上尝试监听。
    private enum Attempt {
        case ok        // 绑定成功并开始监听
        case alive     // 同一个用户的活实例正在这条路径上
        case notMine   // 路径被别的用户的文件占着，无权删除
        case failed    // 其它原因（socket 创建失败、路径过长、listen 失败）
    }

    private func tryListen(_ path: String) -> Attempt {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("control: socket() failed errno=\(errno)")
            return .failed
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            close(fd)
            NSLog("control: socket path too long: \(path)")
            return .failed
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        func tryBind() -> Int32 {
            withUnsafePointer(to: &addr) { p -> Int32 in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
            }
        }
        if tryBind() != 0 {
            // 路径已被占用：先分清"活实例"还是"死残留"，再决定退出还是接管。
            // 探测用 connect——同用户的 socket 是 0600，别人连不上，所以这里不会误判成自己人。
            if socketAlive(path) {
                close(fd)
                return .alive
            }
            // 死残留：能删就删掉重绑。
            // 删不掉时**不能当失败**——典型场景是文件属于另一个 macOS 用户，
            // /tmp 的 sticky bit（drwxrwxrwt）只允许属主删除，我们必然拿到 EPERM。
            // 这不是错误，只是"这条路径不归我"，换下一条候选路径即可。
            if unlink(path) != 0 {
                close(fd)
                NSLog("control: cannot remove \(path) errno=\(errno) — skipping this path")
                return .notMine
            }
            guard tryBind() == 0 else {
                close(fd)
                NSLog("control: bind failed twice errno=\(errno) path=\(path)")
                return .failed
            }
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            NSLog("control: listen failed errno=\(errno) path=\(path)")
            return .failed
        }
        chmod(path, 0o600)
        listenFD = fd
        self.path = path

        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.acceptOne() }
        s.resume()
        source = s
        NSLog("control: listening at \(path)")
        return .ok
    }

    /// 启动控制总线：按候选路径依次尝试。
    /// 单实例锁：先直接 bind（不预先 unlink——那会把前一个实例的 socket 拆掉导致双开）。
    /// 只有"探测到活实例"才判定为重复启动；路径不可用一律降级，不阻塞桌宠本身。
    @discardableResult
    func start(handler: @escaping ([String]) -> [String: String]) -> ControlServerStartResult {
        self.handler = handler
        for candidate in candidates {
            switch tryListen(candidate) {
            case .ok:
                return .ok
            case .alive:
                NSLog("control: another instance is already listening on \(candidate)")
                return .anotherInstance
            case .notMine, .failed:
                continue   // 换下一条候选路径
            }
        }
        NSLog("control: no usable socket path among \(candidates)")
        return .unavailable
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if !path.isEmpty {
            unlink(path)     // 退出即清理：残留文件会在多用户机器上把下一个用户卡住
            path = ""
        }
    }

    private func acceptOne() {
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 2048)
        while raw.count < 8192 {
            let n = recv(client, &buf, buf.count, 0)
            if n <= 0 { break }
            raw.append(contentsOf: buf[0..<n])
            if raw.contains(0x0A) { break }
        }

        let line = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            .trimmingCharacters(in: .whitespaces) ?? ""

        var reply: [String: String]
        if line.isEmpty {
            reply = ["ok": "0", "err": "empty"]
        } else {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if let h = handler {
                reply = DispatchQueue.main.sync { h(tokens) }
            } else {
                reply = ["ok": "0", "err": "no-handler"]
            }
        }

        let json = Self.encode(reply) + "\n"
        json.withCString { recvWrite(client, $0, strlen($0)) }
        close(client)
    }

    private func recvWrite(_ fd: Int32, _ p: UnsafePointer<CChar>, _ n: Int) {
        var sent = 0
        while sent < n {
            let w = write(fd, p + sent, n - sent)
            if w <= 0 { break }
            sent += w
        }
    }

    private static func encode(_ d: [String: String]) -> String {
        let body = d.map { k, v in "\"\(escape(k))\":\"\(escape(v))\"" }.sorted().joined(separator: ",")
        return "{" + body + "}"
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            default:
                if ch.value < 0x20 { out += " " } else { out.unicodeScalars.append(ch) }
            }
        }
        return out
    }
}
