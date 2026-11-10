import Foundation
import IOKit
import IOKit.ps
import MachO

// MARK: - Метрики: CPU, память, батарея, температура

final class StatsSampler: @unchecked Sendable {
    struct Sample {
        var cpuPercent: Double?
        var memUsedBytes: UInt64 = 0
        var memTotalBytes: UInt64 = 0
        var batteryPercent: Int?
        var charging: Bool?
        var temperatureC: Double?
    }

    private var prevTicks: (load: UInt64, idle: UInt64)?
    private let totalMemory: UInt64
    private let pageSize: UInt64

    init() {
        var size = MemoryLayout<UInt64>.size
        var mem: UInt64 = 0
        sysctlbyname("hw.memsize", &mem, &size, nil, 0)
        totalMemory = mem
        var page: UInt64 = 16384
        sysctlbyname("hw.pagesize", &page, &size, nil, 0)
        pageSize = page
    }

    func sample() -> Sample {
        var s = Sample()
        s.cpuPercent = cpuPercent()
        (s.memUsedBytes, s.memTotalBytes) = memory()
        (s.batteryPercent, s.charging) = battery()
        s.temperatureC = TemperatureReader.chipTemperatureC()
        return s
    }

    // MARK: CPU (host_processor_info, разница замеров)

    private func cpuPercent() -> Double? {
        var numCpus: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCpus, &info, &count)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        var load: UInt64 = 0
        var idle: UInt64 = 0
        let per = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(numCpus) {
            let base = cpu * per
            load += UInt64(info[base + Int(CPU_STATE_USER)])
            load += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            load += UInt64(info[base + Int(CPU_STATE_NICE)])
            idle += UInt64(info[base + Int(CPU_STATE_IDLE)])
        }
        defer { prevTicks = (load, idle) }
        guard let prev = prevTicks else { return nil }
        let dLoad = load &- prev.load
        let dIdle = idle &- prev.idle
        let total = dLoad &+ dIdle
        guard total > 0 else { return 0 }
        return Double(dLoad) / Double(total) * 100
    }

    // MARK: Память (host_statistics64)

    private func memory() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, totalMemory) }
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        return (used, totalMemory)
    }

    // MARK: Батарея (IOPowerSources)

    private func battery() -> (percent: Int?, charging: Bool?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, nil)
        }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : nil
            let onAC = desc[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (percent, onAC)
        }
        return (nil, nil)
    }
}

// MARK: - Температура чипа (IOHID, частный API через dlsym)

enum TemperatureReader {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias ClientSetMatching = @convention(c) (OpaquePointer?, CFDictionary?) -> Int32
    private typealias ClientCopyServices = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias ServiceCopyEvent = @convention(c) (OpaquePointer?, UInt32, UInt32, UInt64) -> OpaquePointer?
    private typealias EventGetFloat = @convention(c) (OpaquePointer?, UInt32) -> Double
    private typealias ServiceCopyProperty = @convention(c) (OpaquePointer?, CFString) -> OpaquePointer?
    private typealias ReleaseFn = @convention(c) (OpaquePointer?) -> Void

    private static let kEventTypeTemperature: UInt32 = 15
    private static let kFieldTemperatureLevel: UInt32 = kEventTypeTemperature << 16

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let ptr = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    /// Максимум по датчикам PMU tdie* (кристалл). nil, если датчиков нет.
    static func chipTemperatureC() -> Double? {
        let values = sensors()
            .filter { $0.name.hasPrefix("PMU tdie") && $0.value > 0 && $0.value < 150 }
            .map(\.value)
        return values.max()
    }

    /// Отладка/приёмка: все температурные HID-датчики с именами и значениями.
    static func debugSensors() -> [(name: String, value: Double)] {
        sensors()
    }

    private static func sensors() -> [(name: String, value: Double)] {
        guard let create: ClientCreate = symbol("IOHIDEventSystemClientCreate", as: ClientCreate.self),
              let setMatching: ClientSetMatching = symbol("IOHIDEventSystemClientSetMatching", as: ClientSetMatching.self),
              let copyServices: ClientCopyServices = symbol("IOHIDEventSystemClientCopyServices", as: ClientCopyServices.self),
              let copyEvent: ServiceCopyEvent = symbol("IOHIDServiceClientCopyEvent", as: ServiceCopyEvent.self),
              let getFloat: EventGetFloat = symbol("IOHIDEventGetFloatValue", as: EventGetFloat.self),
              let copyProperty: ServiceCopyProperty = symbol("IOHIDServiceClientCopyProperty", as: ServiceCopyProperty.self),
              let release: ReleaseFn = symbol("CFRelease", as: ReleaseFn.self)
        else { return [] }

        guard let client = create(kCFAllocatorDefault) else { return [] }
        defer { release(client) }

        let matching = [
            "PrimaryUsagePage": 0xFF00,
            "PrimaryUsage": 5
        ] as CFDictionary
        _ = setMatching(client, matching)

        guard let services = copyServices(client) else { return [] }
        defer { release(services) }
        let servicesArray = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(services)).takeUnretainedValue()

        var result: [(String, Double)] = []
        let count = CFArrayGetCount(servicesArray)
        for i in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(servicesArray, i) else { continue }
            let service = OpaquePointer(raw)
            guard let nameRef = copyProperty(service, "Product" as CFString) else { continue }
            let nameObject = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(nameRef)).takeUnretainedValue()
            defer { release(nameRef) }
            guard CFGetTypeID(nameObject) == CFStringGetTypeID() else { continue }
            let name = nameObject as! String
            guard let event = copyEvent(service, kEventTypeTemperature, 0, 0) else { continue }
            defer { release(event) }
            let value = Double(getFloat(event, kFieldTemperatureLevel))
            result.append((name, value))
        }
        return result
    }
}
