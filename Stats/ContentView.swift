import SwiftUI
import Charts

// MARK: - Font size constant (bumped from 12 → 14pt globally)
private let kBodyFont:    Font = .system(size: 14)
private let kCaptionFont: Font = .system(size: 14)
private let kMonoFont:    Font = .system(size: 14, design: .monospaced)
private let kCaption2Font: Font = .system(size: 13)  // was caption2 (~11pt), nudged to 13

// All panels share this height so the grid stays uniform as more rows get added.
private let kPanelHeight: CGFloat = 430

struct ContentView: View {
    @StateObject private var monitor        = SystemMonitor()
    @StateObject private var gpuMonitor     = GPUMonitor()
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var diskMonitor    = DiskMonitor()
    @StateObject private var wifiMonitor    = WifiMonitor()
    @StateObject private var procMonitor    = ProcessMonitor()
    @StateObject private var screenArtMonitor = ScreenArtMonitor()
    @StateObject private var claudeMonitor  = ClaudeMonitor()   // ← new

    @State private var showDeleteBackgroundDBConfirmation = false
    @State private var gpuPanelStatsHeight: CGFloat = 100
    @State private var dragStartOrigin: CGPoint?

    private struct HeightPreferenceKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        VStack(spacing: 5) {

            Spacer(minLength: 5)

            // --- Header ---
            HStack {
                Text("System Status")
                    .font(.title.bold())
                Spacer()
                Text(Date.now.formatted(date: .omitted, time: .standard))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .font(.system(size: 14))
            }
            .padding(.horizontal, 20)
            .padding(.top, 7)
            .padding(.bottom, 0)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard let window = NSApp.windows.first else { return }
                        if dragStartOrigin == nil {
                            dragStartOrigin = window.frame.origin
                        }
                        guard let start = dragStartOrigin else { return }
                        window.setFrameOrigin(NSPoint(
                            x: start.x + value.translation.width,
                            y: start.y - value.translation.height
                        ))
                    }
                    .onEnded { _ in
                        dragStartOrigin = nil
                    }
            )

            // --- Main Grid ---
            ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 15) {

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

                        VStack(spacing: 6) {
                            DiskStatRow(label: "Total", value: "\(Int(monitor.cpuUsage * 100))%")
                            DiskStatRow(label: "User", value: "\(Int(monitor.cpuUserUsage * 100))%")
                            DiskStatRow(label: "System", value: "\(Int(monitor.cpuSystemUsage * 100))%")
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Top Processes").font(kCaptionFont).foregroundStyle(.primary)
                            ForEach(procMonitor.topProcesses.prefix(4)) { process in
                                HStack {
                                    Text(process.name)
                                        .font(.headline).fontWeight(.semibold).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(process.cpu))%")
                                        .font(.title3).monospacedDigit()
                                        .foregroundStyle(process.cpu > 50 ? .red : .primary)
                                }
                            }
                        }

                        Divider()

                        if !monitor.perCoreUsage.isEmpty {
                            CPUCoresChart(cores: monitor.perCoreUsage)
                                .frame(height: 60)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(height: kPanelHeight)

                // 2. GPU Card
                MetricCard(title: "GPU, System, and Disk", value: gpuMonitor.gpuUsage, unit: "%", color: .green,
                           trailingHeader: {
                    AnyView(
                        HStack(spacing: 5) {
                            Text("GPU").font(kCaption2Font).foregroundStyle(.secondary)
                            Text("\(Int(gpuMonitor.gpuUsage * 100))%")
                                .font(.title3).bold().monospacedDigit()
                            if let trend = gpuMonitor.gpuUsageTrend {
                                let points = Int((trend * 100).rounded())
                                let isUp = points >= 0
                                HStack(spacing: 2) {
                                    Image(systemName: isUp ? "arrow.up" : "arrow.down")
                                    Text("\(isUp ? "+" : "")\(points)% (5 min)")
                                }
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(isUp ? .orange : .green)
                            } else {
                                Text("— (5 min)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    )
                }) {
                    VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 12) {
                        Chart(Array(gpuMonitor.gpuHistory.enumerated()), id: \.offset) { index, value in
                            AreaMark(x: .value("Time", index), y: .value("Usage", value))
                                .foregroundStyle(LinearGradient(colors: [.green.opacity(0.6), .green.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                            LineMark(x: .value("Time", index), y: .value("Usage", value)).foregroundStyle(.green)
                        }
                        .chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(maxWidth: .infinity)
                        .frame(height: gpuPanelStatsHeight)

                        VStack(alignment: .leading, spacing: 8) {
                            GPUStatGroup(label: "GPU") {
                                GPUStatChip(icon: "speedometer",
                                            text: gpuMonitor.gpuFrequencyMHz.map { String(format: "%.0f MHz", $0) } ?? "—",
                                            color: .cyan)
                                GPUStatChip(icon: "memorychip",
                                            text: String(format: "%.1f GB", gpuMonitor.gpuMemoryUsedGB),
                                            color: .purple)
                            }
                            GPUStatGroup(label: "System") {
                                GPUStatChip(icon: "thermometer.medium",
                                            text: gpuMonitor.socTemperatureF.map { String(format: "%.0f°F", $0) } ?? "—",
                                            color: .orange)
                                GPUStatChip(icon: "bolt.fill",
                                            text: gpuMonitor.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—",
                                            color: .yellow)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
                            }
                        )
                    }
                    .onPreferenceChange(HeightPreferenceKey.self) { newHeight in
                        gpuPanelStatsHeight = newHeight
                    }

                    Divider().padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        if diskMonitor.volumes.count > 1 {
                            MultiDiskStackedBar(volumes: diskMonitor.volumes)
                        }

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

                                if volume.name == "Internal" {
                                    VStack(spacing: 3) {
                                        DiskStatRow(label: "Read", value: String(format: "%.0f MB/s", diskMonitor.readMBps))
                                        DiskStatRow(label: "Write", value: String(format: "%.0f MB/s", diskMonitor.writeMBps))
                                        DiskStatRow(label: "IOPS", value: diskMonitor.iops.formatted())
                                        DiskStatRow(label: "SMART", value: diskMonitor.smartStatus,
                                                    valueColor: diskMonitor.smartStatus == "Verified" ? .green : .red)
                                        DiskStatRow(label: "TRIM", value: diskMonitor.trimEnabled ? "Enabled" : "Disabled")
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }

                        VStack(alignment: .trailing, spacing: 4) {
                            HStack {
                                Label("BackgroundProcessing DB", systemImage: "cylinder.split.1x2")
                                    .font(kCaptionFont).foregroundStyle(.primary)
                                Spacer()
                                Text(diskMonitor.backgroundDBSizeString).font(kMonoFont)
                            }
                            Button(role: .destructive) {
                                showDeleteBackgroundDBConfirmation = true
                            } label: {
                                Text("Delete File")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(.horizontal, 4)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .controlSize(.large)
                            .offset(x: 6, y: 8)
                        }
                    }
                    }
                }
                .frame(height: kPanelHeight)

                // 3. Memory Card
                MetricCard(title: "Memory", value: 0, unit: "", color: .clear,
                           trailingHeader: {
                    AnyView(
                        HStack(spacing: 5) {
                            Text(monitor.memoryUsedString)
                                .font(.title3).bold().monospacedDigit()
                            if let trend = monitor.memoryUsageTrend {
                                let points = Int((trend * 100).rounded())
                                let isUp = points >= 0
                                HStack(spacing: 2) {
                                    Image(systemName: isUp ? "arrow.up" : "arrow.down")
                                    Text("\(isUp ? "+" : "")\(points)% (5 min)")
                                }
                                .font(.system(size: 11)).monospacedDigit()
                                .foregroundStyle(isUp ? .orange : .green)
                            } else {
                                Text("— (5 min)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    )
                }) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 12) {
                            Chart(monitor.ramSegments) { segment in
                                SectorMark(angle: .value("Memory", segment.value), innerRadius: .ratio(0.6), angularInset: 1.5)
                                    .cornerRadius(4).foregroundStyle(segment.color)
                            }
                            .frame(width: 70, height: 70)

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(monitor.ramSegments) { segment in
                                    HStack(spacing: 6) {
                                        Circle().fill(segment.color).frame(width: 6, height: 6)
                                        Text(segment.type).font(kCaption2Font).foregroundStyle(.primary)
                                        Spacer()
                                        Text(String(format: "%.1f", segment.value))
                                            .font(kCaption2Font).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }

                            Spacer(minLength: 0)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Memory Pressure")
                                .font(kCaption2Font).foregroundStyle(.secondary)
                            MemoryPressureChart(levels: monitor.memoryPressureHistory)
                                .frame(height: 22)
                        }
                    }
                }
                .frame(height: kPanelHeight)

                // 4. Network Card
                NetworkCard(monitor: networkMonitor)
                    .frame(height: kPanelHeight)

                // 5. System & Network Card
                MetricCard(title: "System & Network", value: 0, unit: "", color: .primary) {
                    VStack(alignment: .leading, spacing: 12) {

                        // --- Network info ---
                        HStack {
                            Label("Wi-Fi Status", systemImage: "wifi")
                                .font(kCaptionFont).foregroundStyle(.primary)
                            Spacer()
                            Text("On (\(networkMonitor.wifiRSSI)dBm: \(wifiQuality(rssi: networkMonitor.wifiRSSI)) @ \(Int(networkMonitor.wifiTransmitRate).formatted())Mbps)")
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
                        }

                    }
                    .foregroundStyle(.primary)
                }
                .frame(height: kPanelHeight)

                // 6. ScreenArt Card
                MetricCard(title: "ScreenArt", value: 0, unit: "", color: .clear) {
                    ScrollView {
                        Text(screenArtMonitor.content)
                            .font(kMonoFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxHeight: .infinity)
                    .foregroundStyle(.primary)
                }
                .frame(height: kPanelHeight)
            }
            .padding()
            }
        }
        .alert("Delete BackgroundProcessing DB?", isPresented: $showDeleteBackgroundDBConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                diskMonitor.deleteBackgroundDB()
            }
        } message: {
            Text("This will permanently delete CurrentBackgroundProcessingDB.BGSQL. This cannot be undone.")
        }
        .alert("Couldn't Delete File", isPresented: Binding(
            get: { diskMonitor.deleteBackgroundDBErrorMessage != nil },
            set: { if !$0 { diskMonitor.deleteBackgroundDBErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diskMonitor.deleteBackgroundDBErrorMessage ?? "")
        }
    }

    // MARK: - Subviews & Helpers

    struct MetricCard<Content: View>: View {
        let title: String
        let value: Double
        let unit: String
        let color: Color
        var contentAlignment: Alignment = .top
        var trailingHeader: (() -> AnyView)? = nil
        @ViewBuilder let graph: () -> Content

        var body: some View {
            VStack(alignment: .leading) {
                HStack {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Spacer()
                    if let trailingHeader {
                        trailingHeader()
                    } else if unit == "%" {
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
            .frame(maxHeight: .infinity, alignment: contentAlignment)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.1))
                }
            )
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
    }

    /// Only rendered when there's more than one disk: a thin capacity-proportioned bar with
    /// one segment per disk, each segment itself shaded to show that disk's used/free split.
    struct MultiDiskStackedBar: View {
        let volumes: [DiskVolume]

        private static let colors: [Color] = [.purple, .blue, .teal, .orange, .pink]

        private var totalCapacity: Double { volumes.reduce(0) { $0 + $1.totalGB } }

        var body: some View {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                        let widthFraction = totalCapacity > 0 ? volume.totalGB / totalCapacity : 0
                        let usedFraction = volume.totalGB > 0 ? (volume.totalGB - volume.availableGB) / volume.totalGB : 0
                        let color = Self.colors[index % Self.colors.count]

                        GeometryReader { segment in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.2))
                                RoundedRectangle(cornerRadius: 3).fill(color)
                                    .frame(width: segment.size.width * usedFraction)
                            }
                        }
                        .frame(width: geo.size.width * widthFraction)
                    }
                }
            }
            .frame(height: 8)
        }
    }

    struct DiskStatRow: View {
        let label: String
        let value: String
        var valueColor: Color = .primary

        var body: some View {
            HStack {
                Text(label).font(kCaptionFont).foregroundStyle(.primary)
                Spacer()
                Text(value).font(kMonoFont).monospacedDigit().foregroundStyle(valueColor)
            }
        }
    }

    struct GPUStatGroup<Content: View>: View {
        let label: String
        @ViewBuilder let content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(spacing: 8) {
                    content()
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }

    struct GPUStatChip: View {
        let icon: String
        let text: String
        let color: Color

        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
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

        var coverageLabel: String {
            let elapsed = Int(min(Date().timeIntervalSince(monitor.startTime), 3600))
            if elapsed >= 3600 { return "Last 1h" }
            let mins = elapsed / 60
            let secs = elapsed % 60
            if mins >= 1 { return "Last \(mins)m" }
            return "Last \(secs)s"
        }

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

                        HStack {
                            Text("Total: \(formatter.string(fromByteCount: Int64(monitor.totalBytesDownloaded)))")
                            Spacer()
                            Text("\(coverageLabel): \(formatter.string(fromByteCount: Int64(monitor.hourlyBytesDownloaded)))")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal)
                        .padding(.bottom, 4)
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

                        HStack {
                            Text("Total: \(formatter.string(fromByteCount: Int64(monitor.totalBytesUploaded)))")
                            Spacer()
                            Text("\(coverageLabel): \(formatter.string(fromByteCount: Int64(monitor.hourlyBytesUploaded)))")
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                    }

                    Divider().padding(.vertical, 4)

                    DiskStatRow(label: "Packet Loss", value: String(format: "%.1f%%", monitor.packetLossPercent),
                                valueColor: monitor.packetLossPercent > 1 ? .red : .primary)
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    func statusColor(for value: Double) -> Color {
        if value > 0.8 { return .red }
        else if value > 0.5 { return .orange }
        else { return .green }
    }

    func wifiQuality(rssi: Int) -> String {
        switch rssi {
        case -50...0:   return "Excellent"
        case -67 ..< -50: return "Good"
        case -80 ..< -67: return "Fair"
        case -90 ..< -80: return "Poor"
        default:           return "Unusable"
        }
    }
}
