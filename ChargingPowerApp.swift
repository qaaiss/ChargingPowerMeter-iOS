import SwiftUI
import Combine

// MARK: - App Entry

@main
struct ChargingPowerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

// MARK: - Root View (Tab Bar)

struct RootView: View {
    @StateObject private var viewModel = ChargingViewModel()
    
    var body: some View {
        TabView {
            DashboardView(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "bolt.circle.fill")
                    Text("Dashboard")
                }
            
            HistoryView(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "clock.fill")
                    Text("History")
                }
            
            SettingsView(viewModel: viewModel)
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("Settings")
                }
        }
        // Default layout (left-to-right) for English
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - ViewModel + Models (Real with partial indicators)

final class ChargingViewModel: ObservableObject {
    // Values displayed in UI
    @Published var isCharging: Bool = false
    @Published var batteryLevel: Double = 0.0        // 0 to 1
    @Published var batteryState: UIDevice.BatteryState = .unknown
    
    @Published var estimatedPowerWatt: Double = 0.0  // Approximate watt estimation
    @Published var chargeSpeed: ChargeSpeed = .idle
    @Published var timeRemainingMinutes: Int = 0
    @Published var showBatteryPercentageInCircle: Bool = false
    
    @Published var chargerType: ChargerType = .unknown
    
    // Charging sessions history (currently sample data only)
    @Published var sessions: [ChargingSession] = ChargingSession.sample
    
    // Approximate battery capacity in Watt-hour (example for a modern iPhone)
    private let batteryCapacityWh: Double = 12.0
    
    /// Sample of battery level over time to estimate charging speed
    private struct Sample {
        let level: Double  // 0...1
        let date: Date
    }
    
    private var samples: [Sample] = []
    private var timer: AnyCancellable?
    
    // MARK: - Init / Deinit
    
    init() {
        setupBatteryMonitoring()
        startSamplingTimer()
    }
    
    deinit {
        timer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Battery Monitoring
    
    private func setupBatteryMonitoring() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        
        // Initial read
        batteryLevel = Double(max(0, device.batteryLevel))
        batteryState = device.batteryState
        isCharging = (batteryState == .charging || batteryState == .full)
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.batteryLevelDidChange()
        }
        
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.batteryStateDidChange()
        }
    }
    
    private func batteryLevelDidChange() {
        let device = UIDevice.current
        let newLevel = max(0, device.batteryLevel)
        batteryLevel = Double(newLevel)
        
        addSample(level: Double(newLevel))
        updateEstimatesFromSamples()
    }
    
    private func batteryStateDidChange() {
        let device = UIDevice.current
        batteryState = device.batteryState
        isCharging = (batteryState == .charging || batteryState == .full)
        
        if !isCharging {
            samples.removeAll()
            estimatedPowerWatt = 0
            chargeSpeed = .idle
            timeRemainingMinutes = 0
        }
    }
    
    // MARK: - Sampling Timer
    
    /// Take a sample every 30 seconds while charging to estimate speed & wattage
    private func startSamplingTimer() {
        timer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.isCharging else { return }
                
                let device = UIDevice.current
                let level = max(0, device.batteryLevel)
                self.batteryLevel = Double(level)
                self.addSample(level: Double(level))
                self.updateEstimatesFromSamples()
            }
    }
    
    // MARK: - Sampling Logic
    
    private func addSample(level: Double) {
        let sample = Sample(level: level, date: Date())
        samples.append(sample)
        
        // Keep last 15 minutes only
        let cutoff = Date().addingTimeInterval(-15 * 60)
        samples = samples.filter { $0.date >= cutoff }
    }
    
    private func updateEstimatesFromSamples() {
        guard samples.count >= 2 else {
            estimatedPowerWatt = 0
            chargeSpeed = isCharging ? .normal : .idle
            timeRemainingMinutes = 0
            return
        }
        
        guard isCharging else {
            estimatedPowerWatt = 0
            chargeSpeed = .idle
            timeRemainingMinutes = 0
            return
        }
        
        guard let first = samples.first, let last = samples.last else { return }
        let dt = last.date.timeIntervalSince(first.date) // seconds
        guard dt > 10 else { return }
        
        let dLevel = last.level - first.level
        
        // No real increase in battery level
        guard dLevel > 0 else {
            estimatedPowerWatt = 0
            chargeSpeed = .slow
            timeRemainingMinutes = 0
            return
        }
        
        let dtHours = dt / 3600.0
        let deltaPerHour = dLevel / dtHours     // increase in battery percentage per hour (0...1)
        
        // Estimated watt = Wh * charge rate per hour
        var watt = batteryCapacityWh * deltaPerHour
        
        // Reasonable bounds for iPhone (avoid crazy values)
        watt = max(0, min(watt, 40))
        
        estimatedPowerWatt = watt
        
        // Charging speed classification based on estimated watt
        switch watt {
        case 0..<10:
            chargeSpeed = .slow
        case 10..<20:
            chargeSpeed = .normal
        case 20...:
            chargeSpeed = .fast
        default:
            chargeSpeed = .idle
        }
        
        // Estimate remaining time
        let remainingLevel = max(0.0, 1.0 - batteryLevel)
        if deltaPerHour > 0 {
            let hoursRemaining = remainingLevel / deltaPerHour
            let minutesRemaining = Int(hoursRemaining * 60)
            timeRemainingMinutes = max(0, min(minutesRemaining, 6 * 60)) // Max 6 hours
        } else {
            timeRemainingMinutes = 0
        }
    }
    
    // MARK: - Computed for UI
    
    var batteryPercentageText: String {
        "\(Int(batteryLevel * 100))%"
    }
    
    var formattedPower: String {
        if estimatedPowerWatt <= 0 || !isCharging {
            return "0 W"
        } else {
            return String(format: "%.1f W", estimatedPowerWatt)
        }
    }
    
    var formattedTimeRemaining: String {
        guard timeRemainingMinutes > 0 else {
            if batteryState == .full || batteryLevel >= 0.99 {
                return "Fully charged"
            } else if !isCharging {
                return "Not connected"
            } else {
                return "Estimating..."
            }
        }
        let hours = timeRemainingMinutes / 60
        let minutes = timeRemainingMinutes % 60
        
        if hours > 0 {
            return "\(hours) h · \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }
    
    var chargeStatusText: String {
        if !isCharging {
            if batteryLevel >= 0.99 {
                return "Fully charged"
            } else {
                return "Not connected"
            }
        }
        switch chargeSpeed {
        case .slow:  return "Slow charging"
        case .normal: return "Normal charging"
        case .fast:   return "Fast charging"
        case .idle:   return "Idle"
        }
    }
}

// Charger types (iOS does not expose this directly; mainly for history/manual use)
enum ChargerType: String, CaseIterable, Identifiable {
    case wired = "Wired"
    case magsafe = "MagSafe"
    case wireless = "Wireless"
    case unknown = "Unknown"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .wired:    return "cable.connector"
        case .magsafe:  return "dot.radiowaves.left.and.right"
        case .wireless: return "wave.3.right.circle"
        case .unknown:  return "questionmark.circle"
        }
    }
    
    var description: String {
        switch self {
        case .wired:    return "Charging via cable (manual/estimated)"
        case .magsafe:  return "MagSafe charging (manual/estimated)"
        case .wireless: return "Wireless charging (manual/estimated)"
        case .unknown:  return "iOS does not expose charger type to apps"
        }
    }
}

enum ChargeSpeed: String {
    case slow   = "Slow"
    case normal = "Normal"
    case fast   = "Fast"
    case idle   = "Idle"
    
    var tint: Color {
        switch self {
        case .slow:   return .orange
        case .normal: return .blue
        case .fast:   return .green
        case .idle:   return .gray
        }
    }
}

// Charging session for history (currently sample/demo data)
struct ChargingSession: Identifiable {
    let id = UUID()
    let date: Date
    let durationMinutes: Int
    let averageWatt: Double
    let maxWatt: Double
    let chargerType: ChargerType
    
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    var formattedDuration: String {
        if durationMinutes < 60 {
            return "\(durationMinutes) min"
        } else {
            let hours = durationMinutes / 60
            let minutes = durationMinutes % 60
            if minutes == 0 {
                return "\(hours) h"
            } else {
                return "\(hours) h · \(minutes) min"
            }
        }
    }
    
    static let sample: [ChargingSession] = [
        ChargingSession(date: Date().addingTimeInterval(-3600 * 2),
                        durationMinutes: 54,
                        averageWatt: 21.3,
                        maxWatt: 26.5,
                        chargerType: .wired),
        ChargingSession(date: Date().addingTimeInterval(-3600 * 8),
                        durationMinutes: 120,
                        averageWatt: 17.8,
                        maxWatt: 22.1,
                        chargerType: .magsafe),
        ChargingSession(date: Date().addingTimeInterval(-3600 * 24),
                        durationMinutes: 35,
                        averageWatt: 11.2,
                        maxWatt: 14.9,
                        chargerType: .wireless)
    ]
}

// MARK: - Dashboard View

struct DashboardView: View {
    @ObservedObject var viewModel: ChargingViewModel
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(.systemIndigo),
                        Color(.systemBackground)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        headerSection
                        powerCircleSection
                        quickStatsSection
                        detailsSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("Charging Power")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    // MARK: Header
    
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.chargeStatusText)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Current charging status")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(viewModel.batteryPercentageText)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
                Text("Battery level")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
    
    // MARK: Power Circle
    
    private var powerCircleSection: some View {
        ZStack {
            Circle()
                .stroke(
                    Color.white.opacity(0.15),
                    lineWidth: 22
                )
                .frame(width: 230, height: 230)
            
            Circle()
                .trim(from: 0.0, to: CGFloat(max(viewModel.batteryLevel, 0.05)))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color.green,
                            Color.blue,
                            Color.purple
                        ]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 22, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 230, height: 230)
                .shadow(radius: 10)
            
            VStack(spacing: 6) {
                Image(systemName: viewModel.isCharging ? "bolt.fill" : "bolt.slash.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.yellow.opacity(0.9))
                    .padding(8)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
                
                Text(viewModel.formattedPower)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Estimated charging power")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        viewModel.showBatteryPercentageInCircle.toggle()
                    }
                } label: {
                    Text(
                        viewModel.showBatteryPercentageInCircle
                        ? viewModel.batteryPercentageText
                        : "Show battery percentage"
                    )
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
    
    // MARK: Quick Stats
    
    private var quickStatsSection: some View {
        HStack(spacing: 14) {
            StatCardView(
                title: "Time remaining",
                value: viewModel.formattedTimeRemaining,
                icon: "timer",
                color: .blue.opacity(0.9)
            )
            
            StatCardView(
                title: "Charging speed",
                value: viewModel.chargeSpeed.rawValue,
                subtitle: viewModel.chargeStatusText,
                icon: "speedometer",
                color: viewModel.chargeSpeed.tint
            )
        }
    }
    
    // MARK: Details
    
    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Charging details")
                .font(.headline)
                .foregroundColor(.primary)
                .padding(.horizontal, 4)
            
            VStack(spacing: 12) {
                DetailRow(
                    title: "Charger type",
                    value: viewModel.chargerType.rawValue,
                    icon: viewModel.chargerType.icon,
                    subtitle: viewModel.chargerType.description
                )
                
                DetailRow(
                    title: "Charging speed",
                    value: viewModel.chargeSpeed.rawValue,
                    icon: "speedometer",
                    tint: viewModel.chargeSpeed.tint
                )
                
                DetailRow(
                    title: "Status",
                    value: viewModel.isCharging ? "Charging" : "Not connected",
                    icon: viewModel.isCharging ? "bolt.fill" : "bolt.slash",
                    tint: viewModel.isCharging ? .green : .red
                )
                
                DetailRow(
                    title: "Battery level",
                    value: viewModel.batteryPercentageText,
                    icon: "battery.100"
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 6)
            )
        }
        .padding(.top, 4)
    }
}

// MARK: - Dashboard Subviews

struct StatCardView: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
            }
            
            Text(value)
                .font(.headline)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
        )
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    let icon: String
    var tint: Color = .blue
    var subtitle: String? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(tint)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            
            Spacer()
            
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - History View

struct HistoryView: View {
    @ObservedObject var viewModel: ChargingViewModel
    
    var body: some View {
        NavigationStack {
            List {
                if viewModel.sessions.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No history yet")
                            .font(.headline)
                        Text("Charging sessions will appear here once added.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 40)
                } else {
                    ForEach(viewModel.sessions) { session in
                        HistoryRow(session: session)
                    }
                }
            }
            .navigationTitle("Charging History")
        }
    }
}

struct HistoryRow: View {
    let session: ChargingSession
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: session.chargerType.icon)
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(session.formattedDate)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text(session.formattedDuration)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 3) {
                Text(String(format: "%.1f W", session.averageWatt))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.primary)
                Text("Max: \(String(format: "%.1f", session.maxWatt)) W")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: ChargingViewModel
    @AppStorage("isDarkMode") private var isDarkMode: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Appearance")) {
                    Toggle(isOn: $isDarkMode) {
                        Label("Dark mode", systemImage: isDarkMode ? "moon.fill" : "sun.max.fill")
                    }
                }
                
                Section(header: Text("Display")) {
                    Toggle(isOn: $viewModel.showBatteryPercentageInCircle) {
                        Label("Show battery percentage in circle", systemImage: "battery.100")
                    }
                }
                
                Section(header: Text("About")) {
                    HStack {
                        Text("App version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("Developer")
                        Spacer()
                        Text("Qais")
                            .foregroundColor(.secondary)
                    }
                    
                    Text("Watt value and remaining time are estimates based on battery level changes over time, not direct readings from iOS.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }
            .navigationTitle("Settings")
        }
        .preferredColorScheme(isDarkMode ? .dark : .light)
    }
}

// MARK: - Preview

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
    }
}
