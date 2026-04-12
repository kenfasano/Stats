//
//  ProcessMonitor.swift
//  Stats
//
//  Created by Ken Fasano on 1/20/26.
//

import Foundation
import Combine

class ProcessMonitor: ObservableObject {
    @Published var topProcessName: String = "Loading..."
    @Published var topProcessCPU: Double = 0.0
    
    private var timer: Timer?
    
    init() {
        startMonitoring()
    }
    
    func startMonitoring() {
        // Update every 2 seconds to be efficient
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            self.fetchTopProcess()
        }
        fetchTopProcess() // Initial fetch
    }
    
    private func fetchTopProcess() {
        let task = Process()
        task.launchPath = "/bin/ps"
        // -A: All processes, -c: executable name only, -r: sort by CPU, -o: output specific columns
        task.arguments = ["-Aceo", "pcpu,comm", "-r"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                parseProcessOutput(output)
            }
        } catch {
            print("Failed to fetch top process: \(error)")
        }
    }
    
    private func parseProcessOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        // Line 0 is headers, Line 1 is the top process
        if lines.count > 1 {
            let topLine = lines[1].trimmingCharacters(in: .whitespaces)
            let components = topLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            
            if components.count >= 2 {
                // First component is CPU (e.g., "12.5"), rest is Name (e.g., "WindowServer")
                if let cpuVal = Double(components[0]) {
                    let name = components.dropFirst().joined(separator: " ")
                    
                    DispatchQueue.main.async {
                        self.topProcessCPU = cpuVal
                        self.topProcessName = name
                    }
                }
            }
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}
