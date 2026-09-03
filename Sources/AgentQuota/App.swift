import Combine
import AppKit
import SwiftUI

@main
struct AgentQuotaApp: App {
    @StateObject private var store = QuotaStore()

    var body: some Scene {
        MenuBarExtra {
            QuotaPopoverView(store: store)
                .frame(width: 460)
        } label: {
            Image(systemName: store.hasWarning ? "chart.bar.fill" : "chart.bar")
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}

struct QuotaService: Identifiable, Codable, Equatable {
    var id: UUID
    var appName: String
    var name: String
    var quotaLabel: String
    var plan: String
    var symbol: String
    var current: Int
    var max: Int
    var resetAt: Date
    var accentHex: String
    var resetWindow: String? = nil  // "5h", "5d", "week", "month"
    var disabledReason: String? = nil
    var resetNote: String? = nil

    var percentage: Double {
        guard max > 0 else {
            return 0
        }
        return Swift.min(1, Swift.max(0, Double(current) / Double(max)))
    }

    var percentLabel: String {
        guard max > 0 else {
            return "N/A"
        }
        return "\(Int((percentage * 100).rounded()))%"
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    var resetWindowLabel: String {
        switch resetWindow {
        case "5h", "5 hours": return "5 小時"
        case "5d", "5 days": return "5 天"
        case "week", "weekly", "7d": return "每週"
        case "month", "monthly": return "每月"
        case let w?: return w
        case nil: return ""
        }
    }

    static func demoServices() -> [QuotaService] {
        [
            QuotaService(
                id: UUID(),
                appName: "Claude",
                name: "Claude 5h",
                quotaLabel: "5 小時",
                plan: "Pro",
                symbol: "C",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(29 * 60 * 60),
                accentHex: "#D97757",
                resetWindow: "5h"
            ),
            QuotaService(
                id: UUID(),
                appName: "Claude",
                name: "Claude weekly",
                quotaLabel: "每週",
                plan: "Pro",
                symbol: "C",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(6 * 24 * 60 * 60),
                accentHex: "#D97757",
                resetWindow: "week"
            ),
            QuotaService(
                id: UUID(),
                appName: "Codex",
                name: "Codex 5h",
                quotaLabel: "5 小時",
                plan: "Plus",
                symbol: "O",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(8 * 60 * 60),
                accentHex: "#10A37F",
                resetWindow: "5h"
            ),
            QuotaService(
                id: UUID(),
                appName: "Codex",
                name: "Codex weekly",
                quotaLabel: "每週",
                plan: "Plus",
                symbol: "O",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(6 * 24 * 60 * 60),
                accentHex: "#10A37F",
                resetWindow: "week"
            ),
            QuotaService(
                id: UUID(),
                appName: "Agy Claude/GPT",
                name: "Agy Claude 5h",
                quotaLabel: "Claude/GPT · 5 小時",
                plan: "Pro",
                symbol: "A",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(53 * 60 * 60),
                accentHex: "#D97757",
                resetWindow: "5h"
            ),
            QuotaService(
                id: UUID(),
                appName: "Agy Claude/GPT",
                name: "Agy Claude weekly",
                quotaLabel: "Claude/GPT · 每週",
                plan: "Pro",
                symbol: "A",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(6 * 24 * 60 * 60),
                accentHex: "#D97757",
                resetWindow: "week"
            ),
            QuotaService(
                id: UUID(),
                appName: "Agy Gemini",
                name: "Agy Gemini 5h",
                quotaLabel: "Gemini · 5 小時",
                plan: "Pro",
                symbol: "A",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(5 * 60 * 60),
                accentHex: "#4285F4",
                resetWindow: "5h"
            ),
            QuotaService(
                id: UUID(),
                appName: "Agy Gemini",
                name: "Agy Gemini weekly",
                quotaLabel: "Gemini · 每週",
                plan: "Pro",
                symbol: "A",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(6 * 24 * 60 * 60),
                accentHex: "#4285F4",
                resetWindow: "week"
            ),
            QuotaService(
                id: UUID(),
                appName: "Copilot",
                name: "Copilot",
                quotaLabel: "每月 AI Credits",
                plan: "Copilot Pro",
                symbol: "C",
                current: 0,
                max: 1500,
                resetAt: Date().addingTimeInterval(12 * 24 * 60 * 60),
                accentHex: "#0969DA",
                resetWindow: "month"
            ),
            QuotaService(
                id: UUID(),
                appName: "Grok",
                name: "Grok",
                quotaLabel: "每週 Credits",
                plan: "Grok Build",
                symbol: "G",
                current: 0,
                max: 0,
                resetAt: Date().addingTimeInterval(7 * 24 * 60 * 60),
                accentHex: "#6D5DFB",
                resetWindow: "week",
                resetNote: "Usage amount unavailable"
            ),
        ]
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published private(set) var services: [QuotaService]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var refreshIssues: [String] = []
    @Published private(set) var liveServiceNames: Set<String> = []

    private let storageKey = "agent-quota-services"
    private let storageVersionKey = "agent-quota-version"
    private let grokMigrationKey = "agent-quota-grok-migrated"
    private let currentStorageVersion = 8
    private var timerCancellable: AnyCancellable?
    private var refreshCancellable: AnyCancellable?

    init() {
        let savedVersion = UserDefaults.standard.integer(forKey: storageVersionKey)
        if savedVersion == currentStorageVersion,
            let data = UserDefaults.standard.data(forKey: storageKey),
            let savedServices = try? JSONDecoder().decode([QuotaService].self, from: data)
        {
            services = savedServices
        } else {
            services = QuotaService.demoServices()
            UserDefaults.standard.set(currentStorageVersion, forKey: storageVersionKey)
        }

        if !UserDefaults.standard.bool(forKey: grokMigrationKey) {
            if !services.contains(where: { $0.appName.caseInsensitiveCompare("Grok") == .orderedSame }),
                let grok = QuotaService.demoServices().first(where: {
                    $0.appName.caseInsensitiveCompare("Grok") == .orderedSame
                })
            {
                services.append(grok)
            }
            UserDefaults.standard.set(true, forKey: grokMigrationKey)
        }
        if let data = try? JSONEncoder().encode(services) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }

        timerCancellable = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }

        refreshCancellable = Timer.publish(every: 120, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshLiveData()
            }

        refreshLiveData()
    }

    var warningCount: Int {
        activeServices.filter { $0.percentage >= 0.7 }.count
    }

    var hasWarning: Bool {
        warningCount > 0
    }

    var nextResetService: QuotaService? {
        activeServices
            .filter { $0.disabledReason == nil && $0.resetNote == nil }
            .min { $0.resetAt < $1.resetAt }
    }

    var mostUrgentService: QuotaService? {
        activeServices.max {
            if $0.percentage == $1.percentage {
                return $0.resetAt > $1.resetAt
            }
            return $0.percentage < $1.percentage
        }
    }

    var blockedServices: [QuotaService] {
        activeServices.filter { $0.percentage >= 1 }
    }

    var riskService: QuotaService? {
        if let blocked = blockedServices.min(by: { $0.resetAt < $1.resetAt }) {
            return blocked
        }
        return mostUrgentService
    }

    var sortedServices: [QuotaService] {
        services.sorted {
            if $0.percentage == $1.percentage {
                return $0.resetAt < $1.resetAt
            }
            return $0.percentage > $1.percentage
        }
    }

    var appGroups: [QuotaAppGroup] {
        Dictionary(grouping: activeServices, by: \.appName)
            .map { QuotaAppGroup(name: $0.key, quotas: $0.value) }
            .sorted {
                if $0.highestUsage == $1.highestUsage { return $0.name < $1.name }
                return $0.highestUsage > $1.highestUsage
            }
    }

    /// Once an app has returned live data, omit its unsynchronised demo windows.
    /// This prevents a missing API window (for example Codex `secondary: null`)
    /// from being presented as a real 0% allowance.
    private var activeServices: [QuotaService] {
        let liveApps = Set(services.compactMap { service in
            liveServiceNames.contains(service.name.lowercased()) ? service.appName : nil
        })
        return services.filter { service in
            !liveApps.contains(service.appName) || liveServiceNames.contains(service.name.lowercased())
        }
    }

    func upsert(_ service: QuotaService) {
        if let index = services.firstIndex(where: { $0.id == service.id }) {
            services[index] = service
        } else {
            services.append(service)
        }
        persist()
    }

    func delete(_ service: QuotaService) {
        services.removeAll { $0.id == service.id }
        persist()
    }

    func resetDemoData() {
        services = QuotaService.demoServices()
        persist()
    }

    func refreshLiveData() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                LiveUsageFetcher.fetchAll()
            }.value

            guard let self else {
                return
            }

            var updatedServices = self.services
            var liveNames = self.liveServiceNames

            // A successful provider response is authoritative for which windows
            // currently exist. Clear that app's previous live markers first so a
            // vanished window becomes N/A instead of retaining stale usage.
            for service in updatedServices where result.refreshedApps.contains(service.appName.lowercased()) {
                liveNames.remove(service.name.lowercased())
            }

            for update in result.updates {
                guard let index = updatedServices.firstIndex(where: {
                    $0.name.caseInsensitiveCompare(update.serviceName) == .orderedSame
                }) else {
                    continue
                }

                updatedServices[index].current = update.current
                updatedServices[index].max = update.max
                updatedServices[index].resetAt = update.resetAt
                if let plan = update.plan {
                    updatedServices[index].plan = plan
                }
                if let resetWindow = update.resetWindow {
                    updatedServices[index].resetWindow = resetWindow
                }
                updatedServices[index].disabledReason = update.disabledReason
                updatedServices[index].resetNote = update.resetNote
                liveNames.insert(update.serviceName.lowercased())
            }

            self.services = updatedServices
            self.liveServiceNames = liveNames
            self.refreshIssues = result.issues
            UserDefaults.standard.set(result.issues, forKey: "agent-quota-refresh-issues")
            self.lastRefreshAt = Date()
            self.isRefreshing = false
            self.persist()
        }
    }

    var refreshStatusText: String {
        if isRefreshing {
            return "同步中…"
        }
        if let lastRefreshAt {
            let syncedText = liveServiceNames.isEmpty ? "尚未取得 live data" : "已同步 \(liveServiceNames.count) 個服務"
            return "\(syncedText) · \(Self.clockFormatter.string(from: lastRefreshAt))"
        }
        return "尚未同步"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(services) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct QuotaAppGroup: Identifiable {
    var id: String { name }
    let name: String
    let quotas: [QuotaService]

    var highestUsage: Double { quotas.map(\.percentage).max() ?? 0 }
    var representative: QuotaService { quotas[0] }
    var plan: String { quotas.first?.plan ?? "" }
}

struct QuotaPopoverView: View {
    @ObservedObject var store: QuotaStore
    @State private var editorRoute: EditorRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            overview
            serviceList
            Divider()
            footer
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editorRoute) { route in
            ServiceEditorView(
                service: route.service,
                isNew: route.isNew,
                onSave: { service in
                    store.upsert(service)
                    editorRoute = nil
                },
                onDelete: {
                    store.delete(route.service)
                    editorRoute = nil
                }
            )
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Quota")
                    .font(.system(size: 16, weight: .semibold))
                Text("訂閱與用量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    store.refreshLiveData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .disabled(store.isRefreshing)
                .help("更新目前 usage")

                Button {
                    editorRoute = EditorRoute(service: newService, isNew: true)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderless)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                .help("新增服務")
            }
        }
        .padding(.bottom, 14)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(store.appGroups.count) 個 App")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                if !store.blockedServices.isEmpty {
                    Label("\(store.blockedServices.count) 個可能已被擋", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                } else if store.warningCount > 0 {
                    Label("\(store.warningCount) 個接近上限", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    Label("用量正常", systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }

            if let risk = store.riskService {
                HStack(spacing: 5) {
                    Image(systemName: store.blockedServices.isEmpty ? "arrow.up.right.circle" : "hand.raised.fill")
                    if store.blockedServices.isEmpty {
                        Text("最接近上限：\(risk.name) · \(risk.percentLabel)")
                    } else {
                        Text("目前可能先被擋：\(risk.name)")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(store.blockedServices.isEmpty ? .orange : .red)
            }

            if let nextReset = store.nextResetService {
                let windowText = nextReset.resetWindowLabel.isEmpty
                    ? ""
                    : "\(nextReset.resetWindowLabel) · "
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text("最快重置：\(nextReset.name) · \(windowText)\(resetText(nextReset.resetAt))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 15)
    }

    private var serviceList: some View {
        Group {
            if store.services.isEmpty {
                VStack(spacing: 10) {
                    Text("還沒有服務")
                        .font(.system(size: 13, weight: .medium))
                    Button("新增服務") {
                        editorRoute = EditorRoute(service: newService, isNew: true)
                    }
                    .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10),
                    ],
                    spacing: 10
                ) {
                    ForEach(store.appGroups) { group in
                        AppQuotaCard(
                            group: group,
                            onEdit: { service in
                                editorRoute = EditorRoute(service: service, isNew: false)
                            },
                            liveServiceNames: store.liveServiceNames
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(store.refreshStatusText)
                .font(.system(size: 10))
                .foregroundStyle(store.refreshIssues.isEmpty ? Color.secondary : Color.orange)
            Spacer()
            Text(BuildInfo.displayVersion)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.quaternary)
            Button("重設範例") {
                store.resetDemoData()
            }
            .font(.system(size: 10))
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 13)
    }

    private var newService: QuotaService {
        QuotaService(
            id: UUID(),
            appName: "Custom",
            name: "",
            quotaLabel: "每月",
            plan: "Custom",
            symbol: "+",
            current: 0,
            max: 100,
            resetAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
            accentHex: "#6B6B67"
        )
    }
}

private struct AppQuotaCard: View {
    let group: QuotaAppGroup
    let onEdit: (QuotaService) -> Void
    let liveServiceNames: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ServiceIcon(service: group.representative)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(group.plan)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if group.quotas.contains(where: { liveServiceNames.contains($0.name.lowercased()) }) {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .help("已同步目前 usage")
                }

                if group.highestUsage >= 1 {
                    Text("已達上限")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.red)
                } else if group.highestUsage >= 0.8 {
                    Text("注意")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                }

            }

            HStack(alignment: .top, spacing: 12) {
                ConcentricQuotaGauge(group: ringGroup) { service in
                    onEdit(service)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var displayedQuotas: [QuotaService] {
        let hasLiveQuota = group.quotas.contains {
            liveServiceNames.contains($0.name.lowercased())
        }
        guard hasLiveQuota else { return group.quotas }
        return group.quotas.filter { liveServiceNames.contains($0.name.lowercased()) }
    }

    private var ringGroup: QuotaRingGroup {
        QuotaRingGroup(
            name: group.name,
            quotas: displayedQuotas,
            showsFiveHourNA: ["codex", "claude", "agy claude/gpt", "agy gemini"].contains(group.name.lowercased()) &&
                !displayedQuotas.contains { $0.resetWindow?.lowercased() == "5h" }
        )
    }
}

private struct QuotaRingGroup: Identifiable {
    var id: String { name }
    let name: String
    let quotas: [QuotaService]
    let showsFiveHourNA: Bool
}

private struct ConcentricQuotaGauge: View {
    let group: QuotaRingGroup
    let onEdit: (QuotaService) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                if let service = orderedQuotas.max(by: { $0.percentage < $1.percentage }) {
                    onEdit(service)
                }
            } label: {
                ZStack {
                    ForEach(Array(orderedQuotas.enumerated()), id: \.element.id) { index, service in
                        let inset = CGFloat(index * 10)
                        Circle()
                            .inset(by: inset)
                            .stroke(
                                service.disabledReason == nil
                                    ? Color.primary.opacity(0.09)
                                    : Color.secondary.opacity(0.28),
                                style: StrokeStyle(
                                    lineWidth: 7,
                                    lineCap: .round,
                                    dash: service.disabledReason == nil ? [] : [2, 3]
                                )
                            )
                        if service.disabledReason == nil {
                            Circle()
                                .inset(by: inset)
                                .trim(from: 0, to: service.percentage)
                                .stroke(
                                    progressColor(for: service),
                                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                                )
                                .rotationEffect(.degrees(-90))
                        }
                    }

                    if group.showsFiveHourNA {
                        Circle()
                            .inset(by: 10)
                            .stroke(
                                Color.secondary.opacity(0.28),
                                style: StrokeStyle(lineWidth: 7, dash: [2, 3])
                            )
                    }

                    Text(centerLabel)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)
                .padding(2)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(orderedQuotas) { service in
                    Button { onEdit(service) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(progressColor(for: service))
                                    .frame(width: 5, height: 5)
                                Text(shortWindow(service))
                                Text(service.disabledReason == nil ? service.percentLabel : "Disabled")
                                    .fontWeight(.semibold)
                            }
                            Text(service.disabledReason ?? service.resetNote ?? resetText(service.resetAt))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                    .help("\(service.quotaLabel) · \(service.disabledReason ?? service.resetNote ?? resetText(service.resetAt))")
                }
                if group.showsFiveHourNA {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 5, height: 5)
                        Text("5hr")
                        Text("N/A")
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .help("API 目前未回傳 5-hour rate limit")
                }
            }
        }
    }

    private var orderedQuotas: [QuotaService] {
        group.quotas.sorted { lhs, rhs in
            // The longer window is the outer ring; shorter windows nest inside it.
            windowRank(lhs) > windowRank(rhs)
        }
    }

    private var centerLabel: String {
        guard orderedQuotas.count == 1, let service = orderedQuotas.first else { return "" }
        return service.percentLabel
    }

    private func windowRank(_ service: QuotaService) -> Int {
        switch service.resetWindow?.lowercased() {
        case "month", "monthly": return 3
        case "week", "weekly", "7d": return 2
        case "5h", "5 hours": return 1
        default: return 0
        }
    }

    private func shortWindow(_ service: QuotaService) -> String {
        switch service.resetWindow?.lowercased() {
        case "month", "monthly": return "Monthly"
        case "week", "weekly", "7d": return "Weekly"
        case "5h", "5 hours": return "5hr"
        default: return service.resetWindowLabel
        }
    }

    private func progressColor(for service: QuotaService) -> Color {
        if service.percentage >= 0.9 { return .red }
        if service.percentage >= 0.7 { return .orange }
        return service.accentColor
    }
}

private struct ServiceIcon: View {
    let service: QuotaService

    var body: some View {
        if let image = AgentAppIcon.image(for: service.name) {
            if AgentAppIcon.isTemplate(for: service.name) {
                Image(nsImage: image)
                    .resizable()
                    .foregroundStyle(.primary)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        } else if let fallbackSymbol = AgentAppIcon.fallbackSymbol(for: service.name) {
            let iconColor = AgentAppIcon.fallbackColor(for: service.name, default: service.accentColor)
            Image(systemName: fallbackSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 28, height: 28)
                .background(iconColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text(service.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(service.accentColor)
                .frame(width: 28, height: 28)
                .background(service.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private enum AgentAppIcon {
    private static let applicationPaths: [String: [String]] = [
        "claude": [
            "/Applications/Claude.app",
            "~/Applications/Claude.app",
        ],
        "codex": [
            "/Applications/Codex.app",
            "~/Applications/Codex.app",
        ],
        "agy": [
            "/Applications/Antigravity.app",
            "/Applications/Antigravity IDE.app",
            "~/Applications/Antigravity.app",
            "~/Applications/Antigravity IDE.app",
        ],
        "copilot": [
            "/Applications/GitHub Copilot.app",
            "~/Applications/GitHub Copilot.app",
            "/Applications/Copilot.app",
            "~/Applications/Copilot.app",
        ],
        "grok": [
            "/Applications/Grok.app",
            "~/Applications/Grok.app",
        ],
    ]

    private static let imagePaths: [String: [String]] = [
        "codex": [
            "/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png",
            "~/Applications/ChatGPT.app/Contents/Resources/chatgptTemplate.png",
        ],
    ]

    static func image(for serviceName: String) -> NSImage? {
        guard let provider = provider(for: serviceName) else {
            return nil
        }

        for path in imagePaths[provider, default: []] {
            let expandedPath = NSString(string: path).expandingTildeInPath
            guard let image = NSImage(contentsOfFile: expandedPath) else {
                continue
            }
            image.isTemplate = provider == "codex"
            image.size = NSSize(width: 28, height: 28)
            return image
        }

        for path in applicationPaths[provider, default: []] {
            let expandedPath = NSString(string: path).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                continue
            }

            // Try to load the high-res icon directly from the app bundle's icns file
            // instead of NSWorkspace.shared.icon(forFile:) which returns a low-quality composite
            let bundle = Bundle(path: expandedPath)
            let iconFile = bundle?.infoDictionary?["CFBundleIconFile"] as? String
            if let iconFile = iconFile {
                let iconName = iconFile.hasSuffix(".icns") ? iconFile : "\(iconFile).icns"
                if let resourcePath = bundle?.resourcePath {
                    let iconPath = (resourcePath as NSString).appendingPathComponent(iconName)
                    if let image = NSImage(contentsOfFile: iconPath) {
                        image.isTemplate = provider == "codex"
                        image.size = NSSize(width: 28, height: 28)
                        return image
                    }
                }
            }

            // Fallback to NSWorkspace icon
            let image = NSWorkspace.shared.icon(forFile: expandedPath)
            image.isTemplate = provider == "codex"
            image.size = NSSize(width: 28, height: 28)
            return image
        }
        return nil
    }

    static func isTemplate(for serviceName: String) -> Bool {
        provider(for: serviceName) == "codex"
    }

    static func fallbackSymbol(for serviceName: String) -> String? {
        switch provider(for: serviceName) {
        case "claude":
            return "sparkles"
        case "codex":
            return "terminal.fill"
        case "agy":
            return "wand.and.stars"
        case "copilot":
            return "person.crop.circle.badge.checkmark"
        case "grok":
            return "bolt.fill"
        default:
            return nil
        }
    }

    static func fallbackColor(for serviceName: String, default defaultColor: Color) -> Color {
        provider(for: serviceName) == "codex" ? .primary : defaultColor
    }

    private static func provider(for serviceName: String) -> String? {
        let name = serviceName.lowercased()
        if name.hasPrefix("claude") {
            return "claude"
        }
        if name.hasPrefix("codex") {
            return "codex"
        }
        if name.hasPrefix("agy") {
            return "agy"
        }
        if name == "copilot" {
            return "copilot"
        }
        if name == "grok" {
            return "grok"
        }
        return nil
    }
}

private struct ServiceEditorView: View {
    let isNew: Bool
    let onSave: (QuotaService) -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuotaService
    @State private var currentText: String
    @State private var maxText: String
    @State private var resetWindowText: String
    @State private var errorMessage: String?

    init(
        service: QuotaService,
        isNew: Bool,
        onSave: @escaping (QuotaService) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: service)
        _currentText = State(initialValue: String(service.current))
        _maxText = State(initialValue: String(service.max))
        _resetWindowText = State(initialValue: service.resetWindow ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新增服務" : "編輯服務")
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField("App 名稱", text: $draft.appName)
                TextField("服務名稱", text: $draft.name)
                TextField("儀表標籤", text: $draft.quotaLabel)
                TextField("方案", text: $draft.plan)
                TextField("圖示", text: $draft.symbol)
                TextField("目前用量", text: $currentText)
                TextField("Quota 上限", text: $maxText)
                DatePicker("下次重置", selection: $draft.resetAt, displayedComponents: [.date, .hourAndMinute])
                TextField("重置週期", text: $resetWindowText)
                TextField("識別色", text: $draft.accentHex)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                if !isNew {
                    Button("刪除", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("儲存") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        guard
            !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let current = Int(currentText),
            let max = Int(maxText),
            current >= 0,
            max > 0
        else {
            errorMessage = "請填寫名稱，並確認用量與上限有效。"
            return
        }

        draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.plan = draft.plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : draft.plan
        draft.symbol = String(draft.symbol.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2))
        draft.symbol = draft.symbol.isEmpty ? String(draft.name.prefix(1)).uppercased() : draft.symbol
        draft.current = current
        draft.max = max
        draft.resetWindow = normalizedResetWindow(resetWindowText)
        draft.accentHex = normalizedHex(draft.accentHex)
        onSave(draft)
        dismiss()
    }
}

private struct EditorRoute: Identifiable {
    let service: QuotaService
    let isNew: Bool

    var id: UUID {
        service.id
    }
}

private let resetDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_TW")
    formatter.dateFormat = "M/d HH:mm"
    return formatter
}()

private func resetText(_ date: Date) -> String {
    let remaining = Int(date.timeIntervalSinceNow)
    let dateStr = resetDateFormatter.string(from: date)

    if remaining <= 0 {
        return "已到期 (\(dateStr))"
    }

    let days = remaining / 86_400
    let hours = (remaining % 86_400) / 3_600
    let minutes = (remaining % 3_600) / 60

    let countdown: String
    if days > 0 {
        countdown = "\(days)d \(hours)h 後"
    } else if hours > 0 {
        countdown = "\(hours)h \(minutes)m 後"
    } else {
        countdown = "\(max(1, minutes))m 後"
    }

    return "\(countdown) · \(dateStr)"
}

private func normalizedHex(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = trimmed.hasPrefix("#") ? trimmed : "#\(trimmed)"
    return candidate.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil
        ? candidate.uppercased()
        : "#6B6B67"
}

private func normalizedResetWindow(_ value: String) -> String? {
    let normalized = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    guard !normalized.isEmpty else {
        return nil
    }

    switch normalized {
    case "5h", "5 hours", "5 小時":
        return "5h"
    case "5d", "5 days", "5 天":
        return "5d"
    case "week", "weekly", "7d", "每週":
        return "week"
    case "month", "monthly", "每月":
        return "month"
    default:
        return normalized
    }
}

private extension Color {
    init(hex: String) {
        let value = normalizedHex(hex).dropFirst()
        let number = UInt64(value, radix: 16) ?? 0x6B6B67
        self.init(
            .sRGB,
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255,
            opacity: 1
        )
    }
}
