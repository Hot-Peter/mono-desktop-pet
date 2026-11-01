import Foundation
import IOKit.ps
import SystemConfiguration
import Darwin

/// 网速 / 电量 / 温度：给气泡提供内容。
///
/// 网速这一块以前不准，原因有三个，全部修掉了：
/// 1. 以前把所有网卡（含 lo0 环回、utun 隧道、awdl/llw 空投、ap1 热点）的字节全加起来，
///    lo0 上任何本机通信都会被当成"上网流量"，隧道还会和外层网卡重复计数；
/// 2. getifaddrs 拿到的是 32 位的 if_data.ifi_ibytes，每 4 GiB 就回绕一次，
///    回绕后 `total &- lastTotal` 会得到天文数字；现在改用 NET_RT_IFLIST2 的 64 位计数器；
/// 3. 以前只在"要冒泡的那一刻"才采样，间隔从 2 秒到几分钟不等，速率是长时间平均值；
///    现在固定 0.5 秒采一次，按最近约 1 秒的窗口算瞬时速率。
enum SystemStats {

    // MARK: - 网速

    private struct NetSample { let t: TimeInterval; let rx: UInt64; let tx: UInt64 }
    private struct IfCounters { let rx: UInt64; let tx: UInt64; let up: Bool }

    private static var samples: [NetSample] = []
    private static var iface: String?
    private static var ifaceCheckedAt: TimeInterval = 0

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 由桌宠每 0.5 秒调用一次（不管要不要冒泡），维护采样窗口
    static func pump() {
        let t = uptime()
        let all = readCounters()
        // 当前接口还在就沿用；消失/超时就重新选主接口
        if iface == nil || all[iface!] == nil || t - ifaceCheckedAt > 15 {
            ifaceCheckedAt = t
            iface = primaryInterface(all)
        }
        guard let name = iface, let c = all[name] else {
            samples.removeAll()
            return
        }
        // 接口计数器回绕 / 接口重置：清空窗口重来（否则会出现超大假速率）
        if let last = samples.last, c.rx < last.rx || c.tx < last.tx { samples.removeAll() }
        samples.append(NetSample(t: t, rx: c.rx, tx: c.tx))
        while let f = samples.first, t - f.t > 4 { samples.removeFirst() }
    }

    /// 最近约 1 秒的收发速率（字节/秒）。窗口取"至少 0.9 秒前的样本"做基准，抗抖动
    static func networkRate() -> (rx: Double, tx: Double)? {
        guard samples.count >= 2, let last = samples.last,
              let base = samples.last(where: { last.t - $0.t >= 0.9 }) else { return nil }
        let dt = last.t - base.t
        guard dt > 0.5 else { return nil }
        return (Double(last.rx &- base.rx) / dt, Double(last.tx &- base.tx) / dt)
    }

    /// 如 "↓1.2 MB/s"、"↓86 KB/s ↑0.4 MB/s"、"↓0 B/s"
    static func networkSpeedText() -> String? {
        guard let r = networkRate() else { return nil }
        var s = "↓" + rateText(r.rx)
        if r.tx >= 40 * 1024 { s += " ↑" + rateText(r.tx) }   // 上行小就不显示，免得气泡太长
        return s
    }

    private static func rateText(_ bps: Double) -> String {
        if bps >= 1_048_576 { return String(format: "%.1f MB/s", bps / 1_048_576) }
        if bps >= 102_400 { return String(format: "%.0f KB/s", bps / 1024) }
        if bps >= 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        return String(format: "%.0f B/s", bps)
    }

    /// 调试用：当前接口与速率
    static func netDebug() -> String {
        let r = networkRate()
        let rt = r.map { String(format: "rx=%.0f tx=%.0f", $0.rx, $0.tx) } ?? "no-rate"
        return "iface=\(iface ?? "nil") \(rt) samples=\(samples.count)"
    }

    /// 系统认定的主上网接口（默认路由所在网卡）
    private static func primaryInterface(_ all: [String: IfCounters]) -> String? {
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            if let store = SCDynamicStoreCreate(nil, "stickman-pet" as CFString, nil, nil),
               let v = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
               let name = v["PrimaryInterface"] as? String, !name.isEmpty, all[name] != nil {
                return name
            }
        }
        // 兜底：在 en*/pdp_ip* 里挑一个启用中、累计流量最大的（多网卡机器上通常就是主网卡）
        let cands = all.filter { name, v in
            v.up && (name.hasPrefix("en") || name.hasPrefix("pdp_ip")) && !name.hasPrefix("anpi")
        }
        return cands.max { ($0.value.rx &+ $0.value.tx) < ($1.value.rx &+ $1.value.tx) }?.key
    }

    /// 64 位收/发计数器（NET_RT_IFLIST2 → if_msghdr2.if_data64）
    private static func readCounters() -> [String: IfCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) >= 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) >= 0 else { return [:] }
        var out: [String: IfCounters] = [:]
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var ptr = base
            let end = base.advanced(by: len)
            while ptr < end {
                let hdr = ptr.assumingMemoryBound(to: if_msghdr.self)
                let msglen = Int(hdr.pointee.ifm_msglen)
                if msglen <= 0 { break }
                if Int32(hdr.pointee.ifm_type) == RTM_IFINFO2 {
                    let h2 = ptr.assumingMemoryBound(to: if_msghdr2.self)
                    var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                    if if_indextoname(UInt32(h2.pointee.ifm_index), &nameBuf) != nil {
                        let name = String(cString: nameBuf)
                        let d = h2.pointee.ifm_data
                        let flags = Int32(bitPattern: UInt32(h2.pointee.ifm_flags))
                        let loopback = (flags & IFF_LOOPBACK) != 0
                        let up = (flags & IFF_UP) != 0
                        if !loopback {
                            out[name] = IfCounters(rx: d.ifi_ibytes, tx: d.ifi_obytes, up: up)
                        }
                    }
                }
                ptr = ptr.advanced(by: msglen)
            }
        }
        return out
    }

    // MARK: - 电量 / 温度

    /// 电池电量，台式机返回 nil
    static func batteryText() -> String? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            if let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
               let cap = desc[kIOPSCurrentCapacityKey] as? Int {
                let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
                return charging ? T("电量 \(cap)%（充电中）", "\(cap)% · charging")
                                : T("电量 \(cap)%", "Battery \(cap)%")
            }
        }
        return nil
    }

    /// 系统热状态（不读具体温度值，那个要内核权限）
    static func thermalText() -> String? {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return T("体温正常", "Temp: normal")
        case .fair: return T("有点热了", "A bit warm")
        case .serious: return T("很热了…", "Getting hot…")
        case .critical: return T("烫烫烫！！", "Too hot!!")
        @unknown default: return nil
        }
    }
}
