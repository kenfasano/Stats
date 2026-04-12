//
//  ScreenArtMonitor.swift
//  Stats
//
//  Created by Ken Fasano on 2/28/26.
//

import Foundation
import Combine
import SwiftUI // Added to use AttributedString and colors

class ScreenArtMonitor: ObservableObject {
    @Published var content: AttributedString = "Loading..."
    private var timer: Timer?
    
    // Path to your results file
    private let filePath = ("~/Scripts/ScreenArt/results.txt" as NSString).expandingTildeInPath
    
    init() {
        readFile()
        
        // Update every minute
            timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            self?.readFile()
        }
    }
    
    private func readFile() {
        do {
            let text = try String(contentsOfFile: filePath, encoding: .utf8)
            let styledText = formatText(text)
            
            DispatchQueue.main.async {
                self.content = styledText
            }
        } catch {
            var errorText = AttributedString("Waiting for results...\n(File not found at ~/Scripts/ScreenArt/results.txt)")
            errorText.foregroundColor = .secondary
            
            DispatchQueue.main.async {
                self.content = errorText
            }
        }
    }
    
    // Mimics the Menu Bar logic: checks for ✓/✗, strips them, and applies colors
    private func formatText(_ text: String) -> AttributedString {
        var result = AttributedString()
        let lines = text.components(separatedBy: .newlines)
        
        let isOk = lines[0].contains("✓")
        
        for (index, line) in lines.enumerated() {
            if line.isEmpty {
                if index < lines.count - 1 { result.append(AttributedString("\n")) }
                continue
            }
            
            // Remove the symbols and trim whitespac
            let cleanText = line.replacingOccurrences(of: "✓", with: "")
                                .replacingOccurrences(of: "✗", with: "")
                                .trimmingCharacters(in: .whitespaces)
            
            var attributedLine = AttributedString(cleanText)
            
            // Apply standard label color (.primary) if OK, otherwise make it Red
            attributedLine.foregroundColor = isOk ? .black : .red
            
            result.append(attributedLine)
            
            // Add the newline back unless it's the very last line
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        
        return result
    }
    
    deinit {
        timer?.invalidate()
    }
}
