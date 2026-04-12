//
//  ClaudeMonitor.swift
//  Stats
//
//  Reads ~/.screenart_tokens.json (written by ScreenArt's token_tracker.py)
//  and publishes today's and this month's input/output token totals.
//  Refreshes every 30 seconds.
//

import Foundation
import Combine

class ClaudeMonitor: ObservableObject {
    @Published var todayInput:  String = "—"
    @Published var todayOutput: String = "—"
    @Published var monthInput:  String = "—"
    @Published var monthOutput: String = "—"
    @Published var lastUpdated: String = "—"
    @Published var hasData:     Bool   = false

    private let filePath = (NSString("~/.screenart_tokens.json")).expandingTildeInPath
    private var timer: Timer?

    init() {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.read()
        }
    }

    private func read() {
        guard let data = FileManager.default.contents(atPath: filePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            DispatchQueue.main.async { self.hasData = false }
            return
        }

        let todayIn  = json["today_input"]  as? Int ?? 0
        let todayOut = json["today_output"] as? Int ?? 0
        let monthIn  = json["month_input"]  as? Int ?? 0
        let monthOut = json["month_output"] as? Int ?? 0
        let updated  = json["updated_at"]   as? String ?? ""

        DispatchQueue.main.async {
            self.todayInput  = Self.format(todayIn)
            self.todayOutput = Self.format(todayOut)
            self.monthInput  = Self.format(monthIn)
            self.monthOutput = Self.format(monthOut)
            self.lastUpdated = Self.formatTimestamp(updated)
            self.hasData     = true
        }
    }

    private static func format(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.2fM", Double(n) / 1_000_000)
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1_000)
        default:           return "\(n)"
        }
    }

    private static func formatTimestamp(_ iso: String) -> String {
        let fmt = ISO8601DateFormatter()
        guard let date = fmt.date(from: iso) else { return iso }
        let local = DateFormatter()
        local.timeStyle = .short
        local.dateStyle = .none
        return local.string(from: date)
    }

    deinit { timer?.invalidate() }
}
