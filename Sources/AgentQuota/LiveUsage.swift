import Foundation
import os

struct LiveQuota: Sendable {
    let serviceName: String
    let current: Int
    let max: Int
    let resetAt: Date
    let plan: String?
}

struct LiveUsageResult: Sendable {
    var updates: [LiveQuota] = []
    var issues: [String] = []
}

enum LiveUsageError: LocalizedError, Sendable {
    case executableNotFound(String)
    case processFailed(String, String)
    case timedOut(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name):
            return "\(name) CLI not found"
        case .processFailed(let name, let detail):
            return "\(name) failed: \(detail)"
        case .timedOut(let name):
            return "\(name) timed out"
        case .invalidResponse(let name):
            return "\(name) returned an unexpected usage response"
        }
    }
}

enum LiveUsageFetcher {
    private static let logger = Logger(subsystem: "local.agentquota.app", category: "live-usage")

    static func fetchAll() -> LiveUsageResult {
        var result = LiveUsageResult()

        do {
            result.updates.append(try fetchClaude())
        } catch {
            let message = "Claude: \(error.localizedDescription)"
            result.issues.append(message)
            logger.error("\(message, privacy: .public)")
        }

        do {
            result.updates.append(try fetchCodex())
        } catch {
            let message = "Codex: \(error.localizedDescription)"
            result.issues.append(message)
            logger.error("\(message, privacy: .public)")
        }

        do {
            result.updates.append(try fetchAgy())
        } catch {
            let message = "Agy: \(error.localizedDescription)"
            result.issues.append(message)
            logger.error("\(message, privacy: .public)")
        }

        result.issues.append("Copilot: GitHub 個人帳號目前沒有可用的 quota endpoint")
        return result
    }

    private static func fetchClaude() throws -> LiveQuota {
        let output = try runSimple(
            name: "claude",
            arguments: ["-p", "/usage", "--output-format", "json", "--no-session-persistence"]
        )
        let response = try JSONDecoder().decode(ClaudeResponse.self, from: Data(output.utf8))
        guard let usage = parseClaudeWeeklyUsage(response.result) else {
            throw LiveUsageError.invalidResponse("Claude")
        }

        return LiveQuota(
            serviceName: "Claude",
            current: usage.usedPercent,
            max: 100,
            resetAt: usage.resetAt,
            plan: nil
        )
    }

    private static func fetchAgy() throws -> LiveQuota {
        let output = try runSimple(
            name: "agy",
            arguments: ["-p", "/usage", "--output-format", "json"]
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(AgyResponse.self, from: Data(output.utf8))
        let buckets = response.command.data?.groups.flatMap { group in
            group.buckets.map { (group.name, $0) }
        } ?? []

        guard
            let selected = buckets.min(by: { $0.1.remainingFraction < $1.1.remainingFraction }),
            let resetAt = ISO8601DateFormatter().date(from: selected.1.resetTime)
        else {
            throw LiveUsageError.invalidResponse("Agy")
        }

        return LiveQuota(
            serviceName: "Agy",
            current: Int(((1 - selected.1.remainingFraction) * 100).rounded()),
            max: 100,
            resetAt: resetAt,
            plan: "\(selected.0) · \(selected.1.window == "5h" ? "5h" : "week")"
        )
    }

    private static func fetchCodex() throws -> LiveQuota {
        let response = try runCodexRateLimitRequest()
        let windows = [
            ("primary", response.rateLimits.primary),
            ("secondary", response.rateLimits.secondary),
        ]
        guard
            let selected = windows.compactMap({ label, window in
                window.map { (label, $0) }
            }).max(by: { $0.1.usedPercent < $1.1.usedPercent }),
            let resetTimestamp = selected.1.resetsAt
        else {
            throw LiveUsageError.invalidResponse("Codex")
        }

        let windowLabel: String
        switch selected.1.windowDurationMins {
        case 300:
            windowLabel = "5h"
        case 10_080:
            windowLabel = "week"
        default:
            windowLabel = selected.0
        }

        return LiveQuota(
            serviceName: "Codex",
            current: selected.1.usedPercent,
            max: 100,
            resetAt: Date(timeIntervalSince1970: TimeInterval(resetTimestamp)),
            plan: [response.rateLimits.planType, windowLabel]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
                .optionalIfNotEmpty
        )
    }

    private static func runSimple(name: String, arguments: [String]) throws -> String {
        guard let executableURL = executableURL(named: name) else {
            throw LiveUsageError.executableNotFound(name)
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        configure(process)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()
        if finished.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            throw LiveUsageError.timedOut(name)
        }

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw LiveUsageError.processFailed(name, errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    private static func runCodexRateLimitRequest() throws -> CodexRateLimitResponse {
        guard let executableURL = executableURL(named: "codex") else {
            throw LiveUsageError.executableNotFound("codex")
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let collector = CodexResponseCollector()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        configure(process)
        outputPipe.fileHandleForReading.readabilityHandler = { [collector] handle in
            collector.append(handle.availableData)
        }

        try process.run()

        let requests = [
            "{\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"agent-quota\",\"version\":\"1.0.0\"}}}",
            "{\"method\":\"initialized\"}",
            "{\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":null}",
        ].joined(separator: "\n") + "\n"
        inputPipe.fileHandleForWriting.write(Data(requests.utf8))

        guard collector.responseSemaphore.wait(timeout: .now() + 45) == .success else {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            throw LiveUsageError.timedOut("Codex")
        }

        outputPipe.fileHandleForReading.readabilityHandler = nil
        inputPipe.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
        }

        guard
            let responseData = collector.responseData,
            let response = try? JSONDecoder().decode(CodexRPCResponse.self, from: responseData),
            let result = response.result
        else {
            throw LiveUsageError.invalidResponse("Codex")
        }
        return result
    }

    private static func executableURL(named name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func configure(_ process: Process) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["TERM"] = "dumb"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    }

    private static func parseClaudeWeeklyUsage(_ text: String) -> ClaudeUsage? {
        guard
            let line = text.split(whereSeparator: \.isNewline).first(where: {
                $0.hasPrefix("Current week (all models):")
            })
        else {
            return nil
        }

        let parts = line.split(separator: "·", maxSplits: 1).map(String.init)
        guard
            let percentPart = parts.first,
            let percentText = percentPart.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces)
                .split(separator: "%")
                .first,
            let usedPercent = Int(percentText),
            parts.count == 2,
            let resetAt = parseClaudeDate(
                parts[1]
                    .replacingOccurrences(of: "resets ", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        else {
            return nil
        }

        return ClaudeUsage(usedPercent: usedPercent, resetAt: resetAt)
    }

    private static func parseClaudeDate(_ value: String) -> Date? {
        let pattern = #"^([A-Za-z]{3}) (\d{1,2}) at ([0-9:]+[ap]m) \(([^)]+)\)$"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
            ),
            let monthRange = Range(match.range(at: 1), in: value),
            let dayRange = Range(match.range(at: 2), in: value),
            let timeRange = Range(match.range(at: 3), in: value),
            let timezoneRange = Range(match.range(at: 4), in: value)
        else {
            return nil
        }

        let month = String(value[monthRange])
        let day = String(value[dayRange])
        let rawTime = String(value[timeRange])
        let timezoneName = String(value[timezoneRange])
        let currentYear = Calendar.current.component(.year, from: Date())
        let meridiem = rawTime.suffix(2).uppercased()
        let clock = rawTime.dropLast(2)
        let time = "\(clock) \(meridiem)"

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: timezoneName) ?? .current
        formatter.dateFormat = rawTime.contains(":") ? "MMM d yyyy h:mm a" : "MMM d yyyy h a"

        guard var date = formatter.date(from: "\(month) \(day) \(currentYear) \(time)") else {
            return nil
        }
        if date < Date().addingTimeInterval(-14 * 24 * 60 * 60) {
            date = formatter.date(from: "\(month) \(day) \(currentYear + 1) \(time)") ?? date
        }
        return date
    }
}

private struct ClaudeResponse: Decodable {
    let result: String
}

private struct ClaudeUsage {
    let usedPercent: Int
    let resetAt: Date
}

private struct AgyResponse: Decodable {
    let command: AgyCommand
}

private struct AgyCommand: Decodable {
    let data: AgyData?
}

private struct AgyData: Decodable {
    let groups: [AgyGroup]
}

private struct AgyGroup: Decodable {
    let name: String
    let buckets: [AgyBucket]
}

private struct AgyBucket: Decodable {
    let window: String
    let remainingFraction: Double
    let resetTime: String
}

private struct CodexRPCResponse: Decodable {
    let result: CodexRateLimitResponse?
}

private struct CodexRateLimitResponse: Decodable {
    let rateLimits: CodexRateLimitSnapshot
}

private struct CodexRateLimitSnapshot: Decodable {
    let planType: String?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?
}

private final class CodexResponseCollector: @unchecked Sendable {
    let responseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var buffer = Data()
    private(set) var responseData: Data?

    func append(_ data: Data) {
        guard !data.isEmpty else {
            return
        }

        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)

        while let newline = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: 0..<newline.lowerBound)
            buffer.removeSubrange(0...newline.lowerBound)
            guard
                let object = try? JSONSerialization.jsonObject(with: lineData),
                let dictionary = object as? [String: Any],
                let id = dictionary["id"] as? Int,
                id == 2
            else {
                continue
            }

            responseData = lineData
            responseSemaphore.signal()
        }
    }
}

private extension String {
    var optionalIfNotEmpty: String? {
        isEmpty ? nil : self
    }
}
