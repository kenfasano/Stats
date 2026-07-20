import Foundation
import SwiftUI
import Combine

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

    private let backgroundDBPath = "/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"

    init() {
        updateDisks()
        updateUptime()
        updateBackgroundDBSize()

        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            self.updateDisks()
            self.updateUptime()
        }

        Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { _ in
            self.updateBackgroundDBSize()
        }
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
