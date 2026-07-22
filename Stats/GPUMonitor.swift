//
//  GPUMonitor.swift
//  Stats
//
//  Created by Ken Fasano on 1/15/26.
//

import Foundation
import IOKit
import IOKit.graphics
import Combine
import Metal

class GPUMonitor: ObservableObject {
    @Published var gpuUsage: Double = 0.0 // 0.0 to 1.0
    @Published var gpuHistory: [Double] = []
    @Published var gpuName: String = "Unknown GPU"
    @Published var gpuMemoryUsedGB: Double = 0.0
    @Published var gpuFrequencyMHz: Double?      // nil until the IOReport bridge has a sample
    @Published var socTemperatureF: Double?       // nil if no SMC sensor is available
    @Published var systemPowerWatts: Double?      // nil if no SMC sensor is available
    // Change in GPU usage (fraction, e.g. 0.12 = +12 points) over the trailing 5-minute
    // window. nil until 5 minutes of history have actually been collected.
    @Published var gpuUsageTrend: Double?

    private var timer: Timer?
    private let smc = SMCClient()
    private let ioReportGPU = IOReportGPU()

    // Separate from `gpuHistory` (which drives the 60-second graph) — this covers a full
    // 5 minutes at the same 1Hz cadence, purely to compute the trend.
    private var trendHistory: [Double] = []
    private static let trendWindowSamples = 300

    // Candidate SMC keys for an overall SoC/CPU-die temperature reading. These are the
    // performance-core thermal diodes; Apple Silicon doesn't expose a GPU-isolated sensor.
    private static let socTemperatureKeys = ["Tp2a", "Tp3a", "Tp4a", "Tp5a", "Tp7a", "Tp8a", "Tp9a"]
    // Total system power draw rail.
    private static let systemPowerKeys = ["PSTR", "PDTR"]

    init() {
        self.gpuHistory = Array(repeating: 0.0, count: 60)

        // Fetch the name once on init
        self.gpuName = getGPUName() ?? "Unknown GPU"

        startMonitoring()
    }

    func startMonitoring() {
        // Update every 1 second
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateGPU()
        }
    }

    private func updateGPU() {
        let usage = getGPUUsage()
        let memoryBytes = getGPUMemoryUsedBytes()
        let frequency = ioReportGPU?.sampleFrequencyMHz()
        let temperatureC = smc?.averageValue(candidates: Self.socTemperatureKeys)
        let power = smc?.averageValue(candidates: Self.systemPowerKeys)

        DispatchQueue.main.async {
            self.gpuUsage = usage
            self.addToHistory(usage)
            self.gpuMemoryUsedGB = Double(memoryBytes) / 1_073_741_824.0
            if let frequency { self.gpuFrequencyMHz = frequency }
            if let temperatureC { self.socTemperatureF = temperatureC * 9.0 / 5.0 + 32.0 }
            if let power { self.systemPowerWatts = power }
            self.updateTrend(with: usage)
        }
    }

    private func addToHistory(_ value: Double) {
        if gpuHistory.count >= 60 { gpuHistory.removeFirst() }
        gpuHistory.append(value)
    }

    private func updateTrend(with usage: Double) {
        trendHistory.append(usage)
        if trendHistory.count > Self.trendWindowSamples { trendHistory.removeFirst() }

        guard trendHistory.count >= Self.trendWindowSamples, let oldest = trendHistory.first else {
            gpuUsageTrend = nil
            return
        }
        gpuUsageTrend = usage - oldest
    }
    
    // MARK: - IOKit Magic
    
    /// Returns the GPU usage as a Double between 0.0 and 1.0
    private func getGPUUsage() -> Double {
        var iterator: io_iterator_t = 0
        
        // 1. Match all IOAccelerator services (Drivers for GPUs)
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        
        guard result == kIOReturnSuccess else { return 0.0 }
        
        var serviceObject = IOIteratorNext(iterator)
        var maxUsage = 0.0
        
        while serviceObject != 0 {
            // 2. Get properties for this service
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(serviceObject, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let propertiesDict = properties?.takeRetainedValue() as? [String: Any] {
                
                // 3. Look for "PerformanceStatistics" dictionary
                // This is the private key where macOS hides the live data
                if let stats = propertiesDict["PerformanceStatistics"] as? [String: Any] {
                    
                    // 4. Extract usage. Keys vary slightly by architecture, but "Device Utilization %" is standard.
                    // Values are usually 0-100 integers.
                    if let usage = stats["Device Utilization %"] as? Int {
                        let usagePercent = Double(usage) / 100.0
                        if usagePercent > maxUsage {
                            maxUsage = usagePercent
                        }
                    } else if let usage = stats["gpu-usage"] as? Int { // Fallback for some older Intel drivers
                         let usagePercent = Double(usage) / 100.0
                        if usagePercent > maxUsage {
                            maxUsage = usagePercent
                        }
                    }
                }
            }
            
            IOObjectRelease(serviceObject)
            serviceObject = IOIteratorNext(iterator)
        }
        
        IOObjectRelease(iterator)
        return maxUsage
    }

    /// Returns the GPU's current "in use system memory" in bytes (shared memory on Apple Silicon).
    private func getGPUMemoryUsedBytes() -> UInt64 {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard result == kIOReturnSuccess else { return 0 }

        var serviceObject = IOIteratorNext(iterator)
        var maxMemory: UInt64 = 0

        while serviceObject != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(serviceObject, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let propertiesDict = properties?.takeRetainedValue() as? [String: Any],
               let stats = propertiesDict["PerformanceStatistics"] as? [String: Any],
               let used = stats["In use system memory"] as? Int {
                maxMemory = max(maxMemory, UInt64(used))
            }
            IOObjectRelease(serviceObject)
            serviceObject = IOIteratorNext(iterator)
        }

        IOObjectRelease(iterator)
        return maxMemory
    }

    private func getGPUName() -> String? {
        var iterator: io_iterator_t = 0
        // "IOPCIDevice" often holds the marketing name, or "AGXAccelerator" for Apple Silicon
        // A simple way is to look at the same IOAccelerator objects used above
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        
        if result == kIOReturnSuccess {
            var serviceObject = IOIteratorNext(iterator)
            while serviceObject != 0 {
                // Try to get the name
                 var properties: Unmanaged<CFMutableDictionary>?
                 if IORegistryEntryCreateCFProperties(serviceObject, &properties, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                    let dict = properties?.takeRetainedValue() as? [String: Any] {
                     
                     // Apple Silicon often puts the name in "model" or requires looking up the parent IOService
                     if let model = dict["model"] as? String {
                         IOObjectRelease(serviceObject)
                         IOObjectRelease(iterator)
                         return model
                     }
                 }
                IOObjectRelease(serviceObject)
                serviceObject = IOIteratorNext(iterator)
            }
        }
        IOObjectRelease(iterator)
        
        // Fallback: Metal Device Name (easier for just the name)
        if let device = MTLCreateSystemDefaultDevice() {
            return device.name
        }
        
        return nil
    }
}

