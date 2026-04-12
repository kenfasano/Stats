import SwiftUI
import Charts

// MARK: - Font size constant (bumped from 12 → 14pt globally)
private let kBodyFont:    Font = .system(size: 14)
private let kCaptionFont: Font = .system(size: 14)
private let kMonoFont:    Font = .system(size: 14, design: .monospaced)
private let kCaption2Font: Font = .system(size: 13)  // was caption2 (~11pt), nudged to 13

struct ContentView: View {
    @StateObject private var monitor        = SystemMonitor()
    @StateObject private var gpuMonitor     = GPUMonitor()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var diskMonitor    = DiskMonitor()
    @StateObject private var wifiMonitor    = WifiMonitor()
    @StateObject private var procMonitor    = ProcessMonitor()
    @StateObject private var screenArtMonitor = ScreenArtMonitor()
    @StateObject private var claudeMonitor  = ClaudeMonitor()   // ← new

    var body: some View {
        VStack(spacing: 20) {

            Spacer(minLength: 36)

            // --- Header ---
            HStack {
                Text("System Status")
                    .font(.title2.bold())
                Spacer()
                Text(Date.now.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 0)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            // --- Main Grid ---
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {

                // 1. CPU Card
                MetricCard(title: "CPU Load", value: monitor.cpuUsage, unit: "%", color: statusColor(for: monitor.cpuUsage)) {
                    VStack(spacing: 12) {
                        Chart(Array(monitor.cpuHistory.enumerated()), id: \.offset) { pair in
                            AreaMark(x: .value("Time", pair.offset), y: .value("Usage", pair.element))
                                .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", pair.offset), y: .value("Usage", pair.element))
                                .foregroundStyle(.blue)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: 0...1).frame(height: 50)

                        Divider()

                        HStack {
                            VStack(alignment: .leading) {
                                Text("Top Process").font(kCaptionFont).foregroundStyle(.primary)
                                Text(procMonitor.topProcessName)
                                    .font(.headline).fontWeight(.semibold).lineLimit(1)
                            }
                            Spacer()
                            Text("\(Int(procMonitor.topProcessCPU))%")
                                .font(.title3).monospacedDigit()
                                .foregroundStyle(procMonitor.topProcessCPU > 50 ? .red : .primary)
                        }

                        Divider()

                        if !monitor.perCoreUsage.isEmpty {
                            CPUCoresChart(cores: monitor.perCoreUsage)
                                .frame(height: 30)
                                .padding(.top, 4)
                        }
                    }
                }

                // 2. GPU Card
                MetricCard(title: "GPU", value: gpuMonitor.gpuUsage, unit: "%", color: .green) {
                    Chart(Array(gpuMonitor.gpuHistory.enumerated()), id: \.offset) { index, value in
                        AreaMark(x: .value("Time", index), y: .value("Usage", value))
                            .foregroundStyle(LinearGradient(colors: [.green.opacity(0.6), .green.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", index), y: .value("Usage", value)).foregroundStyle(.green)
                    }
                    .chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden)
                }

                // 3. Network Card
                NetworkCard(monitor: networkMonitor)

                // 4. Memory Card
                MetricCard(title: "Memory", value: 0, unit: "", color: .clear) {
                    HStack {
                        Chart(monitor.ramSegments) { segment in
                            SectorMark(angle: .value("Memory", segment.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                                .cornerRadius(4).foregroundStyle(segment.color)
                        }
                        .frame(width: 80, height: 80)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(monitor.memoryUsedString).font(.title3).bold().monospacedDigit()
                            VStack(alignment: .trailing, spacing: 2) {
                                ForEach(monitor.ramSegments) { segment in
                                    HStack(spacing: 4) {
                                        Text(segment.type).font(kCaption2Font).foregroundStyle(.primary)
                                        Circle().fill(segment.color).frame(width: 6, height: 6)
                                    }
                                }
                            }
                        }
                    }
                }

                // 5. System & Network Card
                MetricCard(title: "System & Network", value: 0, unit: "", color: .primary) {
                    VStack(alignment: .leading, spacing: 12) {

                        // --- Disk volumes ---
                        ForEach(diskMonitor.volumes) { volume in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(volume.name).font(.subheadline).bold()
                                    Spacer()
                                    Text(volume.statusString)
                                        .font(kMonoFont)
                                        .foregroundStyle(.primary)
                                }
                                ProgressView(value: 100 - volume.availablePercent, total: 100).tint(.purple)
                            }
                        }

                        Divider().padding(.vertical, 4)

                        // --- Network info ---
                        HStack {
                            Label("Wi-Fi Status", systemImage: "wifi")
                                .font(kCaptionFont).foregroundStyle(.primary)
                            Spacer()
                            Text("On (\(networkMonitor.wifiRSSI)dBm / \(Int(networkMonitor.wifiTransmitRate))Mbps)")
                                .font(kMonoFont)
                                .foregroundStyle(.primary)
                        }

                        VStack(spacing: 8) {
                            HStack {
                                Label("Local IP", systemImage: "network")
                                    .font(kCaptionFont).foregroundStyle(.primary)
                                Spacer()
                                Text(networkMonitor.localIP).font(kMonoFont)
                            }
                            HStack {
                                Label("Uptime", systemImage: "clock")
                                    .font(kCaptionFont).foregroundStyle(.primary)
                                Spacer()
                                Text(diskMonitor.uptime).font(kMonoFont)
                            }
                            HStack {
                                Label("Wi-Fi Info", systemImage: "wifi")
                                    .font(kCaptionFont).foregroundStyle(.primary)
                                Spacer()
                                Text("\(networkMonitor.wifiRSSI)dBm / \(Int(networkMonitor.wifiTransmitRate))Mbps")
                                    .font(kMonoFont).foregroundStyle(.primary)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(height: 340)   // slightly taller to fit Claude rows
                    .foregroundStyle(.primary)
                }

                // 6. ScreenArt Card
                MetricCard(title: "ScreenArt", value: 0, unit: "", color: .clear) {
                    ScrollView {
                        Text(screenArtMonitor.content)
                            .font(kMonoFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(height: 340)   // match System & Network height
                }
            }
            .padding()
        }
    }

    // MARK: - Subviews & Helpers

    struct MetricCard<Content: View>: View {
        let title: String
        let value: Double
        let unit: String
        let color: Color
        @ViewBuilder let graph: () -> Content

        var body: some View {
            VStack(alignment: .leading) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    if unit == "%" {
                        Text("\(Int(value * 100))%")
                            .font(.title3).bold().monospacedDigit().foregroundStyle(color)
                    } else if !unit.isEmpty {
                        Text("\(value, specifier: "%.1f") \(unit)")
                            .font(.title3).bold().monospacedDigit().foregroundStyle(color)
                    }
                }

                Divider().padding(.vertical, 5)

                graph()
                    .frame(minHeight: 100)
            }
            .padding()
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1))
                }
            )
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
    }

    struct NetworkCard: View {
        @ObservedObject var monitor: NetworkMonitor

        let formatter: ByteCountFormatter = {
            let f = ByteCountFormatter()
            f.allowedUnits = [.useAll]
            f.countStyle = .memory
            return f
        }()

        var body: some View {
            MetricCard(title: "Network", value: 0, unit: "", color: .clear) {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("Download", systemImage: "arrow.down.circle.fill")
                                .font(kCaption2Font).bold().foregroundStyle(.primary)
                            Spacer()
                            Text(formatter.string(fromByteCount: Int64(monitor.downloadRate)) + "/s")
                                .font(.callout).bold().monospacedDigit().foregroundStyle(.blue)
                        }
                        .padding(.horizontal)
                        .padding(.top, 12)

                        Chart(monitor.history) { point in
                            AreaMark(x: .value("Time", point.timestamp), y: .value("Download", point.download))
                                .foregroundStyle(LinearGradient(colors: [.blue.opacity(0.4), .blue.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Time", point.timestamp), y: .value("Download", point.download))
                                .foregroundStyle(.blue)
                                .interpolationMethod(.catmullRom)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 50)
                    }

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("Upload", systemImage: "arrow.up.circle.fill")
                                .font(kCaption2Font).bold().foregroundStyle(.primary)
                            Spacer()
                            Text(formatter.string(fromByteCount: Int64(monitor.uploadRate)) + "/s")
                                .font(.callout).bold().monospacedDigit().foregroundStyle(.red)
                        }
                        .padding(.horizontal)

                        Chart(monitor.history) { point in
                            AreaMark(x: .value("Time", point.timestamp), y: .value("Upload", point.upload))
                                .foregroundStyle(LinearGradient(colors: [.red.opacity(0.4), .red.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("Time", point.timestamp), y: .value("Upload", point.upload))
                                .foregroundStyle(.red)
                                .interpolationMethod(.catmullRom)
                        }
                        .chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 50)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    struct WindowDragGesture: Gesture {
        var body: some Gesture {
            DragGesture().onChanged { gesture in
                guard let window = NSApp.windows.first else { return }
                window.setFrameOrigin(NSPoint(
                    x: window.frame.origin.x + gesture.translation.width,
                    y: window.frame.origin.y + gesture.translation.height
                ))
            }
        }
    }

    func statusColor(for value: Double) -> Color {
        if value > 0.8 { return .red }
        else if value > 0.5 { return .orange }
        else { return .green }
    }
}

