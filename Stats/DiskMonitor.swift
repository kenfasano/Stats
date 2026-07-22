import Foundation
import SwiftUI
import Combine
import IOKit

struct DiskVolume: Identifiable {
    let id = UUID()
    let name: String
    let totalGB: Double
    let availableGB: Double
    let availablePercent: Double
    
    // The clean format you requested
    var statusString: String {
        let usedGB = Int(totalGB - availableGB)
        let total = Int(totalGB)
        let percent = Int(availablePercent)
        return "\(percent)% free (\(usedGB) / \(total) GB)"
    }
}

class DiskMonitor: ObservableObject {
    @Published var volumes: [DiskVolume] = []
    @Published var uptime: String = "0h 0m"
    @Published var backgroundDBSizeString: String = "—"
    @Published var deleteBackgroundDBErrorMessage: String? = nil

    // Internal disk I/O — sourced from the IOBlockStorageDriver's live byte/op counters.
    @Published var readMBps: Double = 0
    @Published var writeMBps: Double = 0
    @Published var iops: Int = 0
    // SMART/TRIM rarely change, so they're refreshed on a slow cadence.
    @Published var smartStatus: String = "—"
    @Published var trimEnabled: Bool = false

    private let backgroundDBPath = "/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"
    private var previousIOStats: (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64)?

    init() {
        updateDisks()
        updateUptime()
        updateBackgroundDBSize()
        updateDiskIO()
        updateSMARTAndTRIM()

        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.updateDisks()
            self.updateUptime()
        }

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.updateDiskIO()
        }

        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { _ in
            self.updateSMARTAndTRIM()
        }

        Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
            self.updateBackgroundDBSize()
        }
    }

    private func updateDiskIO() {
        guard let current = Self.readBlockStorageStats() else { return }
        defer { previousIOStats = current }
        guard let previous = previousIOStats else { return }

        let readBytesDelta  = current.readBytes  >= previous.readBytes  ? current.readBytes  - previous.readBytes  : 0
        let writeBytesDelta = current.writeBytes >= previous.writeBytes ? current.writeBytes - previous.writeBytes : 0
        let readOpsDelta    = current.readOps    >= previous.readOps    ? current.readOps    - previous.readOps    : 0
        let writeOpsDelta   = current.writeOps   >= previous.writeOps   ? current.writeOps   - previous.writeOps    : 0

        let readMBps  = Double(readBytesDelta)  / 1_000_000.0
        let writeMBps = Double(writeBytesDelta) / 1_000_000.0
        let iops = Int(clamping: readOpsDelta + writeOpsDelta)

        DispatchQueue.main.async {
            self.readMBps = readMBps
            self.writeMBps = writeMBps
            self.iops = iops
        }
    }

    private static func readBlockStorageStats() -> (readBytes: UInt64, writeBytes: UInt64, readOps: UInt64, writeOps: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var totalReadBytes: UInt64 = 0, totalWriteBytes: UInt64 = 0
        var totalReadOps: UInt64 = 0, totalWriteOps: UInt64 = 0

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                totalReadBytes  += (stats["Bytes (Read)"] as? UInt64) ?? 0
                totalWriteBytes += (stats["Bytes (Write)"] as? UInt64) ?? 0
                totalReadOps    += (stats["Operations (Read)"] as? UInt64) ?? 0
                totalWriteOps   += (stats["Operations (Write)"] as? UInt64) ?? 0
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return (totalReadBytes, totalWriteBytes, totalReadOps, totalWriteOps)
    }

    private func updateSMARTAndTRIM() {
        let trim = Self.readTrimSupported()

        DispatchQueue.global(qos: .utility).async {
            let smart = Self.readSMARTStatus()
            DispatchQueue.main.async {
                self.smartStatus = smart
                self.trimEnabled = trim
            }
        }
    }

    /// TRIM/UNMAP support is a stable IOKit property on the block storage device itself.
    private static func readTrimSupported() -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if let features = IORegistryEntryCreateCFProperty(service, "IOStorageFeatures" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let unmap = features["Unmap"] as? Bool {
                return unmap
            }
        }
        return false
    }

    /// Apple Silicon internal NVMe drives block raw SMART log-page queries (the same reason
    /// `smartctl` doesn't work on them); `diskutil`/`system_profiler` can still surface a
    /// coarse health verdict via a private plugin, so we read it the same way they do.
    private static func readSMARTStatus() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["info", "/"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "—"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return "—" }

        for line in output.split(separator: "\n") {
            if line.contains("SMART Status:") {
                return line.split(separator: ":", maxSplits: 1)
                    .last?
                    .trimmingCharacters(in: .whitespaces) ?? "—"
            }
        }
        return "—"
    }

    private func updateBackgroundDBSize() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: backgroundDBPath)
        let size = attributes?[.size] as? Int64

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal

        DispatchQueue.main.async {
            self.backgroundDBSizeString = size.flatMap { formatter.string(from: NSNumber(value: $0)) } ?? "—"
        }
    }
    
    func deleteBackgroundDB() {
        do {
            try FileManager.default.removeItem(atPath: backgroundDBPath)
            updateBackgroundDBSize()
        } catch {
            deleteBackgroundDBWithElevatedPrivileges()
        }
    }

    private func deleteBackgroundDBWithElevatedPrivileges() {
        let path = backgroundDBPath
        DispatchQueue.global(qos: .userInitiated).async {
            let script = "do shell script \"rm -f '\(path)'\" with administrator privileges"
            var errorDict: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&errorDict)

            DispatchQueue.main.async {
                if let errorDict = errorDict {
                    let errorNumber = errorDict[NSAppleScript.errorNumber] as? Int ?? 0
                    if errorNumber != -128 { // -128 = user cancelled the auth prompt
                        self.deleteBackgroundDBErrorMessage = errorDict[NSAppleScript.errorMessage] as? String ?? "Failed to delete file."
                    }
                } else {
                    self.updateBackgroundDBSize()
                }
            }
        }
    }

    private func updateUptime() {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boottime, &size, nil, 0) != -1 {
            let bootDate = Date(timeIntervalSince1970: TimeInterval(boottime.tv_sec))
            let uptimeInterval = Date().timeIntervalSince(bootDate)
            let hours = Int(uptimeInterval) / 3600
            let minutes = (Int(uptimeInterval) % 3600) / 60
            
            DispatchQueue.main.async {
                self.uptime = "\(hours)h \(minutes)m"
            }
        }
    }
    
    private func updateDisks() {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        
        guard let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) else { return }
        
        var newVolumes: [DiskVolume] = []
        
        for url in mountedVolumes {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity else { continue }
            
            var displayName: String? = nil
            if url.path == "/" { displayName = "Internal" }
            else if url.path == "/Volumes/Shared" { displayName = "Shared" }
            // Add other volumes here if needed...
            
            if let finalName = displayName {
                let totalGB = Double(total) / 1_073_741_824.0
                let availGB = Double(available) / 1_073_741_824.0
                let percent = (availGB / totalGB) * 100.0
                
                newVolumes.append(DiskVolume(name: finalName, totalGB: totalGB, availableGB: availGB, availablePercent: percent))
            }
        }
        
        newVolumes.sort { $0.name == "Internal" ? true : $1.name == "Internal" ? false : $0.name < $1.name }
        
        DispatchQueue.main.async {
            self.volumes = newVolumes
        }
    }
}
