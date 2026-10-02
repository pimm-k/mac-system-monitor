import Foundation
import Darwin
import IOKit
import SystemConfiguration

// MARK: - スナップショット型

struct CPUSnapshot: Sendable {
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var perCore: [Double] = []
}

struct MemSnapshot: Sendable {
    var total: UInt64 = 0
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsed: UInt64 = 0
    var available: UInt64 { total > used ? total - used : 0 }
    var percent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

struct DiskSnapshot: Sendable {
    var name: String = "Macintosh HD"
    var readRate: Double = 0
    var writeRate: Double = 0
    var active: Double = 0
    var capacity: UInt64 = 0
    var available: UInt64 = 0
}

struct NetSnapshot: Sendable, Identifiable, Hashable {
    let id: String            // BSD 名 (en0 など)
    var name: String          // 表示名 (Wi-Fi など)
    var rx: Double = 0        // 受信 バイト/秒
    var tx: Double = 0        // 送信 バイト/秒
    var ipv4: [String] = []
    var ipv6: [String] = []
    var mac: String?
}

struct GPUSnapshot: Sendable {
    var name: String = "GPU"
    var utilization: Double = 0
    var memoryUsed: UInt64 = 0
    var cores: Int?
}

struct SystemSnapshot: Sendable {
    var cpu = CPUSnapshot()
    var mem = MemSnapshot()
    var disk = DiskSnapshot()
    var nets: [NetSnapshot] = []
    var gpu: GPUSnapshot?
    var uptime: TimeInterval = 0
    var load: [Double] = [0, 0, 0]
}

struct StaticInfo: Sendable {
    let cpuBrand: String
    let physicalCores: Int
    let logicalCores: Int
    let pCores: Int?
    let eCores: Int?
    let model: String
    let arch: String
    let osVersion: String
    let totalMemory: UInt64

    static func load() -> StaticInfo {
        #if arch(arm64)
        let arch = "Apple Silicon (arm64)"
        #else
        let arch = "Intel (x86_64)"
        #endif
        return StaticInfo(
            cpuBrand: Sysctl.string("machdep.cpu.brand_string") ?? "CPU",
            physicalCores: Sysctl.int("hw.physicalcpu") ?? 0,
            logicalCores: Sysctl.int("hw.logicalcpu") ?? 0,
            pCores: Sysctl.int("hw.perflevel0.physicalcpu"),
            eCores: Sysctl.int("hw.perflevel1.physicalcpu"),
            model: Sysctl.string("hw.model") ?? "",
            arch: arch,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            totalMemory: UInt64(Sysctl.int("hw.memsize") ?? 0)
        )
    }
}

// MARK: - サンプラー

final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let totalMemory: UInt64
    private let bootTime: TimeInterval

    private var prevTicks: [(u: UInt32, s: UInt32, i: UInt32, n: UInt32)] = []
    private var prevDisk: (r: UInt64, w: UInt64, tr: UInt64, tw: UInt64, t: UInt64)?
    private var prevNet: [String: (rx: UInt32, tx: UInt32, t: UInt64)] = [:]
    private var ifaceNames: [String: String] = [:]
    private var tickCount = 0
    private var cachedCapacity: (name: String, total: UInt64, avail: UInt64) = ("Macintosh HD", 0, 0)

    init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = UInt64(ps == 0 ? 16384 : ps)
        totalMemory = UInt64(Sysctl.int("hw.memsize") ?? 0)

        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 {
            bootTime = TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6
        } else {
            bootTime = Date().timeIntervalSince1970
        }
        ifaceNames = Self.interfaceNames()
    }

    func sample() -> SystemSnapshot {
        tickCount += 1
        if tickCount % 30 == 0 { ifaceNames = Self.interfaceNames() }

        var s = SystemSnapshot()
        s.cpu = sampleCPU()
        s.mem = sampleMemory()
        s.disk = sampleDisk()
        s.nets = sampleNetwork()
        s.gpu = sampleGPU()
        s.uptime = Date().timeIntervalSince1970 - bootTime
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.load = load }
        return s
    }

    // MARK: CPU

    private func sampleCPU() -> CPUSnapshot {
        var numCPU: natural_t = 0
        var info: processor_info_array_t? = nil
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &count) == KERN_SUCCESS,
              let info else { return CPUSnapshot() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }

        var snap = CPUSnapshot()
        var newTicks: [(u: UInt32, s: UInt32, i: UInt32, n: UInt32)] = []
        var sumUser = 0.0, sumSys = 0.0, sumAll = 0.0
        for c in 0..<Int(numCPU) {
            let base = Int(CPU_STATE_MAX) * c
            let u = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)])
            let sy = UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)])
            let id = UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])
            let n = UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            newTicks.append((u, sy, id, n))
            if c < prevTicks.count {
                let p = prevTicks[c]
                let du = Double(u &- p.u), ds = Double(sy &- p.s)
                let di = Double(id &- p.i), dn = Double(n &- p.n)
                let tot = du + ds + di + dn
                snap.perCore.append(tot > 0 ? (du + ds + dn) / tot * 100 : 0)
                sumUser += du + dn
                sumSys += ds
                sumAll += tot
            } else {
                snap.perCore.append(0)
            }
        }
        prevTicks = newTicks
        if sumAll > 0 {
            snap.user = sumUser / sumAll * 100
            snap.system = sumSys / sumAll * 100
            snap.total = min(100, snap.user + snap.system)
        }
        return snap
    }

    // MARK: メモリ

    private func sampleMemory() -> MemSnapshot {
        var m = MemSnapshot()
        m.total = totalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            m.app = (internalPages > purgeable ? internalPages - purgeable : 0) * pageSize
            m.wired = UInt64(stats.wire_count) * pageSize
            m.compressed = UInt64(stats.compressor_page_count) * pageSize
            m.cached = (UInt64(stats.external_page_count) + purgeable) * pageSize
            m.used = min(m.total, m.app + m.wired + m.compressed)
        }

        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 {
            m.swapTotal = xsw.xsu_total
            m.swapUsed = xsw.xsu_used
        }
        return m
    }

    // MARK: ディスク

    private func sampleDisk() -> DiskSnapshot {
        var d = DiskSnapshot()
        var r: UInt64 = 0, w: UInt64 = 0, tr: UInt64 = 0, tw: UInt64 = 0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            var obj = IOIteratorNext(iter)
            while obj != 0 {
                if let stats = IORegistryEntryCreateCFProperty(obj, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    r += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    w += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                    tr += (stats["Total Time (Read)"] as? NSNumber)?.uint64Value ?? 0
                    tw += (stats["Total Time (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
                IOObjectRelease(obj)
                obj = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if let p = prevDisk, now > p.t {
            let dt = Double(now - p.t)
            d.readRate = r >= p.r ? Double(r - p.r) / dt * 1e9 : 0
            d.writeRate = w >= p.w ? Double(w - p.w) / dt * 1e9 : 0
            let busy = Double((tr >= p.tr ? tr - p.tr : 0) + (tw >= p.tw ? tw - p.tw : 0))
            d.active = min(100, busy / dt * 100)
        }
        prevDisk = (r, w, tr, tw, now)

        if tickCount % 10 == 1 {
            let url = URL(fileURLWithPath: "/")
            if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeLocalizedNameKey]) {
                cachedCapacity = (v.volumeLocalizedName ?? "Macintosh HD",
                                  UInt64(max(0, v.volumeTotalCapacity ?? 0)),
                                  UInt64(max(0, v.volumeAvailableCapacityForImportantUsage ?? 0)))
            }
        }
        d.name = cachedCapacity.name
        d.capacity = cachedCapacity.total
        d.available = cachedCapacity.avail
        return d
    }

    // MARK: ネットワーク

    private func sampleNetwork() -> [NetSnapshot] {
        var ifap: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }

        var counters: [String: (rx: UInt32, tx: UInt32, up: Bool, mac: String?)] = [:]
        var v4: [String: [String]] = [:]
        var v6: [String: [String]] = [:]

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            let ifa = p.pointee
            cursor = ifa.ifa_next
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en"), let addr = ifa.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)

            if family == AF_LINK, let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                let flags = ifa.ifa_flags
                let up = (flags & UInt32(IFF_UP)) != 0 && (flags & UInt32(IFF_RUNNING)) != 0
                // sockaddr_dl から MAC アドレス
                let raw = UnsafeRawPointer(addr)
                let nlen = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
                let alen = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
                var mac: String? = nil
                if alen == 6 {
                    mac = (0..<6).map { String(format: "%02x", raw.load(fromByteOffset: 8 + nlen + $0, as: UInt8.self)) }
                        .joined(separator: ":")
                }
                counters[name] = (d.ifi_ibytes, d.ifi_obytes, up, mac)
            } else if family == AF_INET || family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    if family == AF_INET { v4[name, default: []].append(s) } else { v6[name, default: []].append(s) }
                }
            }
        }

        let now = DispatchTime.now().uptimeNanoseconds
        var result: [NetSnapshot] = []
        var newPrev: [String: (rx: UInt32, tx: UInt32, t: UInt64)] = [:]
        for (bsd, c) in counters {
            newPrev[bsd] = (c.rx, c.tx, now)
            guard c.up, v4[bsd] != nil || v6[bsd] != nil else { continue }
            var n = NetSnapshot(id: bsd, name: ifaceNames[bsd] ?? bsd)
            if let p = prevNet[bsd], now > p.t {
                let dt = Double(now - p.t)
                n.rx = Double(c.rx &- p.rx) / dt * 1e9
                n.tx = Double(c.tx &- p.tx) / dt * 1e9
            }
            n.ipv4 = v4[bsd] ?? []
            n.ipv6 = v6[bsd] ?? []
            n.mac = c.mac
            result.append(n)
        }
        prevNet = newPrev
        return result.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private static func interfaceNames() -> [String: String] {
        var map: [String: String] = [:]
        for case let iface as SCNetworkInterface in SCNetworkInterfaceCopyAll() as NSArray {
            if let bsd = SCNetworkInterfaceGetBSDName(iface) as String?,
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) as String? {
                map[bsd] = name
            }
        }
        return map
    }

    // MARK: GPU

    private func sampleGPU() -> GPUSnapshot? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }
        var result: GPUSnapshot? = nil
        var obj = IOIteratorNext(iter)
        while obj != 0 {
            if result == nil,
               let stats = IORegistryEntryCreateCFProperty(obj, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                var g = GPUSnapshot()
                g.utilization = (stats["Device Utilization %"] as? NSNumber)?.doubleValue
                    ?? (stats["GPU Activity(%)"] as? NSNumber)?.doubleValue ?? 0
                g.memoryUsed = (stats["In use system memory"] as? NSNumber)?.uint64Value
                    ?? (stats["vramUsedBytes"] as? NSNumber)?.uint64Value ?? 0
                let model = IORegistryEntryCreateCFProperty(obj, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                if let s = model as? String {
                    g.name = s
                } else if let d = model as? Data {
                    g.name = String(decoding: d.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                g.cores = (IORegistryEntryCreateCFProperty(obj, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.intValue
                result = g
            }
            IOObjectRelease(obj)
            obj = IOIteratorNext(iter)
        }
        return result
    }
}
