//
//  NetworkMonitor.swift
//  Stats
//
//  Created by Ken Fasano on 1/15/26.
//

import Foundation
import Combine
import CoreWLAN

class NetworkMonitor: ObservableObject {
    @Published var downloadRate: Double = 0.0
    @Published var uploadRate: Double = 0.0
    @Published var history: [NetworkPoint] = []
    @Published var packetLossPercent: Double = 0.0
    
    // UI Observed Properties
    @Published var wifiRSSI: Int = 0
    @Published var wifiNoise: Int = 0
    @Published var wifiTransmitRate: Double = 0.0
    @Published var localIP: String = "127.0.0.1"
    
    // UI Observed Properties – totals
    @Published var totalBytesDownloaded: Double = 0.0
    @Published var totalBytesUploaded: Double = 0.0
    @Published var hourlyBytesDownloaded: Double = 0.0
    @Published var hourlyBytesUploaded: Double = 0.0

    let startTime = Date()

    private var lastTotalBytesIn: UInt64 = 0
    private var lastTotalBytesOut: UInt64 = 0
    private var lastTotalPacketsIn: UInt64 = 0
    private var lastTotalPacketErrorsIn: UInt64 = 0
    private var timer: Timer?

    // Rolling 1-hour window (one entry per second, up to 3600)
    private var hourlyBuffer: [(down: Double, up: Double)] = []
    private var hourlyWindowDown: Double = 0.0
    private var hourlyWindowUp: Double = 0.0
    
    struct NetworkPoint: Identifiable {
        let id = UUID()
        let timestamp: Date
        let download: Double
        let upload: Double
    }
    
    init() {
        let now = Date()
        self.history = (0..<60).map { i in
            NetworkPoint(timestamp: now.addingTimeInterval(Double(-i)), download: 0, upload: 0)
        }.reversed()
        
        startMonitoring()
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateNetworkStats()
        }
    }
    
    func getDetailedWiFi() -> (rssi: Int, noise: Int, rate: Double) {
        if let interface = CWWiFiClient.shared().interface() {
            return (interface.rssiValue(), interface.noiseMeasurement(), interface.transmitRate())
        }
        return (0, 0, 0.0)
    }
    
    private func updateNetworkStats() {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        defer { freeifaddrs(ifaddr) }
        
        var ptr = ifaddr
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var totalPacketsIn: UInt64 = 0
        var totalPacketErrorsIn: UInt64 = 0

        while ptr != nil {
            let interface = ptr!.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("lo") {
                    if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        totalIn += UInt64(data.pointee.ifi_ibytes)
                        totalOut += UInt64(data.pointee.ifi_obytes)
                        totalPacketsIn += UInt64(data.pointee.ifi_ipackets)
                        totalPacketErrorsIn += UInt64(data.pointee.ifi_ierrors) + UInt64(data.pointee.ifi_iqdrops)
                    }
                }
            }
            ptr = ptr?.pointee.ifa_next
        }
        
        self.updateLocalIP()
        let wifiStats = getDetailedWiFi()
        
        if lastTotalBytesIn > 0 && lastTotalBytesOut > 0 {
            let downDiff = Double(totalIn) - Double(lastTotalBytesIn)
            let upDiff = Double(totalOut) - Double(lastTotalBytesOut)
            let safeDown = downDiff >= 0 ? downDiff : 0
            let safeUp = upDiff >= 0 ? upDiff : 0

            let packetsDiff = Double(totalPacketsIn) - Double(lastTotalPacketsIn)
            let errorsDiff = Double(totalPacketErrorsIn) - Double(lastTotalPacketErrorsIn)
            let safePackets = max(packetsDiff, 0)
            let safeErrors = max(errorsDiff, 0)
            let lossPercent = safePackets + safeErrors > 0 ? (safeErrors / (safePackets + safeErrors)) * 100 : 0

            DispatchQueue.main.async {
                self.downloadRate = safeDown
                self.uploadRate = safeUp
                self.addToHistory(down: safeDown, up: safeUp)
                self.packetLossPercent = lossPercent

                self.wifiRSSI = wifiStats.rssi
                self.wifiNoise = wifiStats.noise
                self.wifiTransmitRate = wifiStats.rate
            }
        }

        lastTotalBytesIn = totalIn
        lastTotalBytesOut = totalOut
        lastTotalPacketsIn = totalPacketsIn
        lastTotalPacketErrorsIn = totalPacketErrorsIn
    }
    
    private func addToHistory(down: Double, up: Double) {
        if history.count >= 60 { history.removeFirst() }
        history.append(NetworkPoint(timestamp: Date(), download: down, upload: up))

        totalBytesDownloaded += down
        totalBytesUploaded += up

        hourlyWindowDown += down
        hourlyWindowUp += up
        hourlyBuffer.append((down: down, up: up))
        if hourlyBuffer.count > 3600 {
            let removed = hourlyBuffer.removeFirst()
            hourlyWindowDown -= removed.down
            hourlyWindowUp -= removed.up
        }

        hourlyBytesDownloaded = hourlyWindowDown
        hourlyBytesUploaded = hourlyWindowUp
    }
    
    private func updateLocalIP() {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while ptr != nil {
                defer { ptr = ptr?.pointee.ifa_next }
                let interface = ptr!.pointee
                let addrFamily = interface.ifa_addr.pointee.sa_family
                if addrFamily == UInt8(AF_INET) {
                    let name = String(cString: interface.ifa_name)
                    if name == "en0" || name == "en1" { // en0 is standard for Wi-Fi
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, UInt32(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        DispatchQueue.main.async {
            self.localIP = address ?? "Disconnected"
        }
    }
}
