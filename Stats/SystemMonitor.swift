import Foundation
import Combine
import Darwin
import SwiftUI
import Charts

// 1. Structure for Pie Chart Data
struct RAMSegment: Identifiable {
    let id = UUID()
    let type: String
    let value: Double // in GB
    let color: Color
}

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0.0
    @Published var cpuUserUsage: Double = 0.0
    @Published var cpuSystemUsage: Double = 0.0
    @Published var cpuHistory: [Double] = []
    @Published var perCoreUsage: [Double] = []
    
    // Memory Properties
    @Published var ramSegments: [RAMSegment] = []
    @Published var memoryTotal: Double = 0.0
    @Published var memoryUsedString: String = "0/0 GB"

    // Memory pressure — the same kernel-reported level (normal/warn/critical) Activity
    // Monitor's "Memory Pressure" graph is built from, distinct from the App/Cached/etc. split.
    @Published var memoryPressureLevel: Int32 = 1
    @Published var memoryPressureHistory: [Int32] = []

    // Change in memory usage (fraction of total, e.g. 0.05 = +5 points) over the trailing
    // 5-minute window. nil until 5 minutes of history have actually been collected.
    @Published var memoryUsageTrend: Double?
    private var memoryTrendHistory: [Double] = []
    private static let trendWindowSamples = 300

    private var timer: Timer?
    private var previousInfo = processor_info_array_t(bitPattern: 0)
    private var previousCount = mach_msg_type_number_t(0)
    
    init() {
        self.memoryTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        self.cpuHistory = Array(repeating: 0.0, count: 60)
        self.memoryPressureHistory = Array(repeating: 1, count: 60)
        startMonitoring()
    }

    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateCPU()
            self.updateMemory()
            self.updateMemoryPressure()
        }
    }

    private func updateMemoryPressure() {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return }

        DispatchQueue.main.async {
            self.memoryPressureLevel = level
            if self.memoryPressureHistory.count >= 60 { self.memoryPressureHistory.removeFirst() }
            self.memoryPressureHistory.append(level)
        }
    }
    
    private func updateCPU() {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t!
        var numCpuInfo: mach_msg_type_number_t = 0
        
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
        
        if result == KERN_SUCCESS {
            var totalUsage = 0.0
            var totalUserUsage = 0.0
            var totalSystemUsage = 0.0
            var newCoreUsages: [Double] = []

            if let prevInfo = previousInfo {
                for i in 0..<Int(numCPUs) {
                    let base = Int32(i) * CPU_STATE_MAX
                    let userTicks   = cpuInfo[Int(base) + Int(CPU_STATE_USER)] - prevInfo[Int(base) + Int(CPU_STATE_USER)]
                    + (cpuInfo[Int(base) + Int(CPU_STATE_NICE)] - prevInfo[Int(base) + Int(CPU_STATE_NICE)])
                    let systemTicks = cpuInfo[Int(base) + Int(CPU_STATE_SYSTEM)] - prevInfo[Int(base) + Int(CPU_STATE_SYSTEM)]
                    let inUse = userTicks + systemTicks
                    let total = inUse + (cpuInfo[Int(base) + Int(CPU_STATE_IDLE)] - prevInfo[Int(base) + Int(CPU_STATE_IDLE)])

                    var coreLoad = 0.0
                    if total > 0 { coreLoad = Double(inUse) / Double(total) }
                    newCoreUsages.append(coreLoad)
                    totalUsage += coreLoad
                    if total > 0 {
                        totalUserUsage += Double(userTicks) / Double(total)
                        totalSystemUsage += Double(systemTicks) / Double(total)
                    }
                }

                let avgUsage = totalUsage / Double(numCPUs)
                let avgUserUsage = totalUserUsage / Double(numCPUs)
                let avgSystemUsage = totalSystemUsage / Double(numCPUs)
                DispatchQueue.main.async {
                    self.cpuUsage = avgUsage
                    self.cpuUserUsage = avgUserUsage
                    self.cpuSystemUsage = avgSystemUsage
                    self.perCoreUsage = newCoreUsages
                    self.addToHistory(avgUsage)
                }
            }
            if previousInfo != nil {
                let prevSize = Int(previousCount) * MemoryLayout<natural_t>.size
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousInfo), vm_size_t(prevSize))
            }
            previousInfo = cpuInfo
            previousCount = numCpuInfo
        }
    }
    
    private func addToHistory(_ value: Double) {
        if cpuHistory.count >= 60 { cpuHistory.removeFirst() }
        cpuHistory.append(value)
    }
    
    // MARK: - Memory Calculation (Required for Pie Chart)
    private func updateMemory() {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var size = vm_size_t(0)
        host_page_size(mach_host_self(), &size)
        
        var vmStats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &vmStats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let gb = 1_073_741_824.0

            let active     = (Double(vmStats.active_count) * Double(size)) / gb
            let wired      = (Double(vmStats.wire_count) * Double(size)) / gb
            let compressed = (Double(vmStats.compressor_page_count) * Double(size)) / gb
            let free       = (Double(vmStats.free_count) * Double(size)) / gb
            let inactive   = (Double(vmStats.inactive_count) * Double(size)) / gb
            let swapUsed   = Self.getSwapUsedGB()

            let appMemory = active + wired
            let usedTotal = appMemory + compressed + inactive

            let newSegments = [
                RAMSegment(type: "App", value: appMemory, color: .blue),
                RAMSegment(type: "Cached", value: inactive, color: .teal),
                RAMSegment(type: "Compressed", value: compressed, color: .pink),
                RAMSegment(type: "Swap", value: swapUsed, color: .red),
                RAMSegment(type: "Free", value: free, color: .gray.opacity(0.4))
            ]

            DispatchQueue.main.async {
                self.ramSegments = newSegments
                self.memoryUsedString = String(format: "%.1f / %.0f GB", usedTotal, self.memoryTotal)
                self.updateMemoryTrend(usedTotal: usedTotal)
            }
        }
    }

    private func updateMemoryTrend(usedTotal: Double) {
        guard memoryTotal > 0 else { return }
        let usedPercent = usedTotal / memoryTotal

        memoryTrendHistory.append(usedPercent)
        if memoryTrendHistory.count > Self.trendWindowSamples { memoryTrendHistory.removeFirst() }

        guard memoryTrendHistory.count >= Self.trendWindowSamples, let oldest = memoryTrendHistory.first else {
            memoryUsageTrend = nil
            return
        }
        memoryUsageTrend = usedPercent - oldest
    }

    private static func getSwapUsedGB() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used) / 1_073_741_824.0
    }

    deinit { timer?.invalidate() }
}

// Helper View for the memory pressure strip (mirrors Activity Monitor's Memory Pressure graph)
struct MemoryPressureChart: View {
    let levels: [Int32]

    private func height(for level: Int32) -> Double {
        switch level {
        case 4: return 1.0    // critical
        case 2: return 0.6    // warning
        default: return 0.25  // normal
        }
    }

    private func color(for level: Int32) -> Color {
        switch level {
        case 4: return .red
        case 2: return .yellow
        default: return .green
        }
    }

    var body: some View {
        Chart {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                BarMark(x: .value("Time", index), y: .value("Level", height(for: level)))
                    .foregroundStyle(color(for: level))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
    }
}

// Helper View for CPU Bar Chart
struct CPUCoresChart: View {
    let cores: [Double]
    
    func isEfficiencyCore(at index: Int) -> Bool {
        if cores.count == 8 { return index < 4 }
        return index < 2
    }
    
    var body: some View {
        Chart {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                BarMark(
                    x: .value("Core", index),
                    y: .value("Usage", usage)
                )
                .foregroundStyle(isEfficiencyCore(at: index) ? Color.red : Color.blue)
                
                BarMark(
                    x: .value("Core", index),
                    y: .value("Empty", max(0, 1.0 - usage))
                )
                .foregroundStyle(Color.secondary.opacity(0.1))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...1)
    }
}
