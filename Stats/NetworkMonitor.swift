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
    
    // UI Observed Properties
    @Published var wifiRSSI: Int = 0
    @Published var wifiNoise: Int = 0
    @Published var wifiTransmitRate: Double = 0.0
    @Published var localIP: String = "127.0.0.1"
    
    private var lastTotalBytesIn: UInt64 = 0
    private var lastTotalBytesOut: UInt64 = 0
    private var timer: Timer?
    
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
        
        while ptr != nil {
            let interface = ptr!.pointee
            if interface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: interface.ifa_name)
                if !name.hasPrefix("lo") {
                    if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                        totalIn += UInt64(data.pointee.ifi_ibytes)
                        totalOut += UInt64(data.pointee.ifi_obytes)
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
            
            DispatchQueue.main.async {
                self.downloadRate = safeDown
                self.uploadRate = safeUp
                self.addToHistory(down: safeDown, up: safeUp)
                
                self.wifiRSSI = wifiStats.rssi
                self.wifiNoise = wifiStats.noise
                self.wifiTransmitRate = wifiStats.rate
            }
        }
        
        lastTotalBytesIn = totalIn
        lastTotalBytesOut = totalOut
    }
    
    private func addToHistory(down: Double, up: Double) {
        if history.count >= 60 { history.removeFirst() }
        history.append(NetworkPoint(timestamp: Date(), download: down, upload: up))
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
