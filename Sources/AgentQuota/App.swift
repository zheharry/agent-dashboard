import Combine
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
    var name: String
    var plan: String
    var symbol: String
    var current: Int
    var max: Int
    var resetAt: Date
    var accentHex: String

    var percentage: Double {
        guard max > 0 else {
            return 0
        }
        return Swift.min(1, Swift.max(0, Double(current) / Double(max)))
    }

    var percentLabel: String {
        "\(Int((percentage * 100).rounded()))%"
    }

    var accentColor: Color {
        Color(hex: accentHex)
    }

    static func demoServices() -> [QuotaService] {
        [
            QuotaService(
                id: UUID(),
                name: "Claude",
                plan: "Pro",
                symbol: "C",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(29 * 60 * 60),
                accentHex: "#D97757"
            ),
            QuotaService(
                id: UUID(),
                name: "Codex",
                plan: "Plus",
                symbol: "O",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(8 * 60 * 60),
                accentHex: "#10A37F"
            ),
            QuotaService(
                id: UUID(),
                name: "Agy Claude",
                plan: "Pro",
                symbol: "A",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(53 * 60 * 60),
                accentHex: "#D97757"
            ),
            QuotaService(
                id: UUID(),
                name: "Agy Gemini",
                plan: "Pro",
                symbol: "A",
                current: 0,
                max: 100,
                resetAt: Date().addingTimeInterval(53 * 60 * 60),
                accentHex: "#4285F4"
            ),
            QuotaService(
                id: UUID(),
                name: "Copilot",
                plan: "Pro",
                symbol: "C",
                current: 2000,
                max: 2000,
                resetAt: Date().addingTimeInterval(126 * 60 * 60),
                accentHex: "#0969DA"
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
    private let currentStorageVersion = 3
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
        services.filter { $0.percentage >= 0.7 }.count
    }

    var hasWarning: Bool {
        warningCount > 0
    }

    var nextResetService: QuotaService? {
        services.min { $0.resetAt < $1.resetAt }
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
                Text("\(store.services.count) 個服務")
                    .font(.system(size: 22, weight: .semibold))
                Spacer()
                if store.warningCount > 0 {
                    Label("\(store.warningCount) 個接近上限", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    Label("用量正常", systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.green)
                }
            }

            if let nextReset = store.nextResetService {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text("下一個重置：\(nextReset.name) · \(resetText(nextReset.resetAt))")
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
                    ForEach(store.services) { service in
                        QuotaCard(
                            service: service,
                            onEdit: {
                            editorRoute = EditorRoute(service: service, isNew: false)
                            },
                            isLive: store.liveServiceNames.contains(service.name.lowercased())
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
            name: "",
            plan: "Custom",
            symbol: "+",
            current: 0,
            max: 100,
            resetAt: Date().addingTimeInterval(30 * 24 * 60 * 60),
            accentHex: "#6B6B67"
        )
    }
}

private struct QuotaCard: View {
    let service: QuotaService
    let onEdit: () -> Void
    let isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text(service.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(service.accentColor)
                    .frame(width: 28, height: 28)
                    .background(service.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(service.plan)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isLive {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .help("已同步目前 usage")
                }

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("編輯 \(service.name)")
            }

            HStack(alignment: .firstTextBaseline) {
                Text("\(service.current.formatted()) / \(service.max.formatted())")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                Text(service.percentLabel)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                    Capsule()
                        .fill(progressColor)
                        .frame(width: geometry.size.width * service.percentage)
                }
            }
            .frame(height: 4)

            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                Text("重置")
                Spacer()
                Text(resetText(service.resetAt))
                    .fontWeight(.medium)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }

    private var progressColor: Color {
        if service.percentage >= 0.9 {
            return .red
        }
        if service.percentage >= 0.7 {
            return .orange
        }
        return service.accentColor
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
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "新增服務" : "編輯服務")
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField("服務名稱", text: $draft.name)
                TextField("方案", text: $draft.plan)
                TextField("圖示", text: $draft.symbol)
                TextField("目前用量", text: $currentText)
                TextField("Quota 上限", text: $maxText)
                DatePicker("下次重置", selection: $draft.resetAt, displayedComponents: [.date, .hourAndMinute])
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
