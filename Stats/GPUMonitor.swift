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
    
    private var timer: Timer?
    
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
        
        DispatchQueue.main.async {
            self.gpuUsage = usage
            self.addToHistory(usage)
        }
    }
    
    private func addToHistory(_ value: Double) {
        if gpuHistory.count >= 60 { gpuHistory.removeFirst() }
        gpuHistory.append(value)
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

