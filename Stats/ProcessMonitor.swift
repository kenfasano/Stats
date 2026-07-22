//
//  ProcessMonitor.swift
//  Stats
//
//  Created by Ken Fasano on 1/20/26.
//

import Foundation
import Combine

struct TopProcess: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double
}

class ProcessMonitor: ObservableObject {
    @Published var topProcessName: String = "Loading..."
    @Published var topProcessCPU: Double = 0.0
    @Published var topProcesses: [TopProcess] = []

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
        // Line 0 is headers, Line 1+ are processes sorted by CPU descending
        guard lines.count > 1 else { return }

        var parsed: [TopProcess] = []
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard components.count >= 2, let cpuVal = Double(components[0]) else { continue }
            let name = components.dropFirst().joined(separator: " ")
            parsed.append(TopProcess(name: name, cpu: cpuVal))
            if parsed.count == 4 { break }
        }

        guard let top = parsed.first else { return }
        DispatchQueue.main.async {
            self.topProcessCPU = top.cpu
            self.topProcessName = top.name
            self.topProcesses = parsed
        }
    }
    
    deinit {
        timer?.invalidate()
    }
}
