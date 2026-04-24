import Darwin
import Foundation
import IOKit

// Bytes-per-category memory breakdown. Categories match Activity Monitor:
//   App      — anonymous pages (app allocations, minus purgeable)
//   Wired    — kernel/driver-locked pages
//   Compressed — compressor-held pages
//   Cached   — file-backed + purgeable (reclaimable)
//   Free     — truly free (minus speculative prefetch)
// `pressure` is the number we treat as "used" for the status-bar % :
//   pressure = (app + wired + compressed) / total
// which avoids false alarms from legitimately high caches.
struct MemoryBreakdown: Encodable {
    let total: UInt64
    let app: UInt64
    let wired: UInt64
    let compressed: UInt64
    let cached: UInt64
    let free: UInt64

    var used: UInt64       { app + wired + compressed + cached }
    var pressure: Double   { total > 0 ? Double(app + wired + compressed) / Double(total) * 100 : 0 }
    var headroom: Double   { total > 0 ? Double(app + wired + compressed + cached) / Double(total) * 100 : 0 }
}

struct MetricsSnapshot: Encodable {
    let cpu: Double
    let memory: Double            // legacy: equals mem.pressure, kept for JS compatibility
    let memBreakdown: MemoryBreakdown
    let gpuUsage: Double           // -1.0 = N/A
    let diskUsed: UInt64
    let diskTotal: UInt64
    var diskPercent: Double { diskTotal > 0 ? Double(diskUsed) / Double(diskTotal) * 100 : 0 }

    enum CodingKeys: String, CodingKey {
        case cpu, memory, memBreakdown, gpuUsage, diskUsed, diskTotal, diskPercent
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cpu,          forKey: .cpu)
        try c.encode(memory,       forKey: .memory)
        try c.encode(memBreakdown, forKey: .memBreakdown)
        try c.encode(gpuUsage,     forKey: .gpuUsage)
        try c.encode(diskUsed,     forKey: .diskUsed)
        try c.encode(diskTotal,    forKey: .diskTotal)
        try c.encode(diskPercent,  forKey: .diskPercent)
    }
}

enum SystemMetrics {
    // Accumulated CPU ticks for delta calculation between samples
    private static var prevTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64) = (0, 0, 0, 0)

    static func snapshot() -> MetricsSnapshot {
        let mem = memoryBreakdown()
        return MetricsSnapshot(
            cpu:          cpuUsage(),
            memory:       mem.pressure,
            memBreakdown: mem,
            gpuUsage:     gpuUsage(),
            diskUsed:     diskUsed(),
            diskTotal:    diskTotal()
        )
    }

    // MARK: - CPU

    private static func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0)
        let sys  = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        let dUser = user - prevTicks.user
        let dSys  = sys  - prevTicks.sys
        let dIdle = idle - prevTicks.idle
        let dNice = nice - prevTicks.nice
        let total = dUser + dSys + dIdle + dNice

        prevTicks = (user, sys, idle, nice)

        guard total > 0 else { return 0 }
        return Double(dUser + dSys + dNice) / Double(total) * 100
    }

    // MARK: - Memory

    static func memoryBreakdown() -> MemoryBreakdown {
        var memSize: UInt64 = 0
        var sizeOfMemSize = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &memSize, &sizeOfMemSize, nil, 0)

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, memSize > 0 else {
            return MemoryBreakdown(total: memSize, app: 0, wired: 0, compressed: 0, cached: 0, free: 0)
        }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let ps = UInt64(pageSize)

        // Mirror Activity Monitor's definitions.
        // internal_page_count = anonymous (app) pages including purgeable.
        // external_page_count = file-backed pages (caches, mmapped files).
        let internalBytes   = UInt64(stats.internal_page_count)      * ps
        let externalBytes   = UInt64(stats.external_page_count)      * ps
        let purgeableBytes  = UInt64(stats.purgeable_count)          * ps
        let wireBytes       = UInt64(stats.wire_count)               * ps
        let compBytes       = UInt64(stats.compressor_page_count)    * ps
        let freeRaw         = UInt64(stats.free_count)               * ps
        let specBytes       = UInt64(stats.speculative_count)        * ps

        let app    = internalBytes &- min(internalBytes, purgeableBytes)
        let cached = externalBytes &+ purgeableBytes
        let free   = freeRaw &- min(freeRaw, specBytes)

        return MemoryBreakdown(
            total:      memSize,
            app:        app,
            wired:      wireBytes,
            compressed: compBytes,
            cached:     cached,
            free:       free
        )
    }

    // MARK: - GPU

    // Safely extract a Double from heterogeneous IOKit numeric types.
    private static func numericValue(_ any: Any?) -> Double? {
        guard let v = any else { return nil }
        if let n = v as? NSNumber  { return n.doubleValue }
        if let i = v as? Int       { return Double(i) }
        if let i = v as? Int64     { return Double(i) }
        if let i = v as? Int32     { return Double(i) }
        if let d = v as? Double    { return d }
        if let f = v as? Float     { return Double(f) }
        return nil
    }

    // Query a single IOKit service class for GPU utilisation.
    // Returns the best (highest) utilisation % found across all matching
    // services, or nil if no data could be extracted.
    private static func queryGPUUtil(className: String) -> Double? {
        let matching = IOServiceMatching(className)
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var best: Double? = nil
        var service = IOIteratorNext(iter)
        while service != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            var propsRef: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &propsRef,
                                                    kCFAllocatorDefault, 0) == KERN_SUCCESS else { continue }
            guard let props = propsRef?.takeRetainedValue() as? [String: Any],
                  let perf  = props["PerformanceStatistics"] as? [String: Any] else { continue }

            // "Device Utilization %" covers Intel, AMD, and some Apple Silicon configs.
            if let util = numericValue(perf["Device Utilization %"]), util >= 0 {
                best = max(best ?? 0.0, util)
                continue
            }

            // Apple Silicon (AGX) fallback: Renderer + Tiler utilisation
            // are the two pipeline stages; their average is a valid proxy.
            // Key names differ across macOS versions — check both variants.
            let renderer = numericValue(perf["Renderer Utilization %"])
                        ?? numericValue(perf["Renderer Utilization"]) ?? 0.0
            let tiler    = numericValue(perf["Tiler Utilization %"])
                        ?? numericValue(perf["Tiler Utilization"])    ?? 0.0
            if renderer > 0 || tiler > 0 {
                best = max(best ?? 0.0, (renderer + tiler) / 2.0)
            }
        }
        return best
    }

    private static func gpuUsage() -> Double {
        // Intel / AMD path
        if let util = queryGPUUtil(className: "IOAccelerator") {
            return util
        }
        // Apple Silicon (M-series) path
        if let util = queryGPUUtil(className: "AGXAccelerator") {
            return util
        }
        return -1.0
    }

    // MARK: - Disk

    private static func diskUsed() -> UInt64 {
        var st = statfs()
        guard statfs("/", &st) == 0 else { return 0 }
        let bs = UInt64(st.f_bsize)
        return (UInt64(st.f_blocks) - UInt64(st.f_bfree)) * bs
    }

    private static func diskTotal() -> UInt64 {
        var st = statfs()
        guard statfs("/", &st) == 0 else { return 0 }
        return UInt64(st.f_blocks) * UInt64(st.f_bsize)
    }
}
