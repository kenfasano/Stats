import Foundation
import Combine
import Network

class WifiMonitor: ObservableObject {
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "WifiMonitor")
    
    // We publish these so the UI updates automatically
    @Published var isConnected: Bool = false
    @Published var statusText: String = "Checking..."
    @Published var iconName: String = "wifi.slash"

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateStatus(path: path)
            }
        }
        monitor.start(queue: queue)
    }

    private func updateStatus(path: NWPath) {
        if path.status == .satisfied {
            self.isConnected = true
            self.statusText = "Wi-Fi: On"
            self.iconName = "wifi"
        } else {
            self.isConnected = false
            self.statusText = "Wi-Fi: Down"
            self.iconName = "wifi.slash"
        }
    }
    
    deinit {
        monitor.cancel()
    }
}
