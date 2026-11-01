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
final class ControlServer {
    private let path: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "stickman.control", qos: .utility)
    private var handler: (([String]) -> [String: String])?

    init(path: String) {
        self.path = path
    }

    /// 探测 socket 后面是否有活实例在监听：能连上 = 有（连上即关，空连接对端无害）
    private func socketAlive() -> Bool {
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

    /// 启动控制总线。返回 false = 已有实例在跑（调用方应退出自己）。
    /// 单实例锁：先直接 bind（不预先 unlink——那会把前一个实例的 socket 拆掉导致双开）。
    /// bind 被占时区分"活实例"（探测连接成功→返回 false）与"崩溃残留"（连不上→清文件重绑）。
    @discardableResult
    func start(handler: @escaping ([String]) -> [String: String]) -> Bool {
        self.handler = handler

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("control: socket() failed errno=\(errno)")
            return false
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            close(fd)
            NSLog("control: socket path too long")
            return false
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
            if socketAlive() {
                close(fd)
                NSLog("control: another instance is running on \(path)")
                return false
            }
            unlink(path)   // 崩溃残留的 socket 文件，清掉重绑
            guard tryBind() == 0 else {
                close(fd)
                NSLog("control: bind failed twice errno=\(errno) path=\(path)")
                return false
            }
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            NSLog("control: listen failed errno=\(errno)")
            return false
        }
        chmod(path, 0o600)
        listenFD = fd

        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.acceptOne() }
        s.resume()
        source = s
        NSLog("control: listening at \(path)")
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
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
