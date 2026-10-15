//
//  ClaudeCodeBridge.swift
//  StickyNotch
//
//  Shows when Claude Code is working, waiting on you, or done, in the notch.
//  Claude Code's "http" hooks POST to a tiny loopback-only listener here:
//    POST /claude/PermissionRequest  → "Claude asked you a question" notice (you answer in the terminal)
//    POST /claude/Stop               → "Claude finished" notice
//  Every request must carry the X-StickyNotch-Token header. Every reply is an empty 200, which Claude Code
//  treats as "no decision", so it always shows its normal terminal prompt.
//

import AppKit
import Defaults
import Network
import SwiftUI

@MainActor
final class ClaudeCodeBridge: ObservableObject {
    static let shared = ClaudeCodeBridge()

    /// Claude is waiting on you in the terminal. Shown until you open the notch, Claude moves on, or a minute passes.
    @Published private(set) var askingProject: String?
    /// Shown until you open the notch (or for a minute)
    @Published private(set) var finishedProject: String?
    /// session_id → project, for sessions with a prompt in flight
    @Published private(set) var running: [String: (project: String, since: Date)] = [:]

    /// Same spring the notch uses to open, so the strip and notices grow out of the notch.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    /// Most recent session still working. ponytail: ignores sessions silent for 2h (crashed without SessionEnd)
    var runningProject: String? {
        running.values.filter { Date().timeIntervalSince($0.since) < 7200 }.max { $0.since < $1.since }?.project
    }

    nonisolated static let port: UInt16 = 47823
    private var listener: NWListener?
    private var finishedTask: Task<Void, Never>?
    private var askingTask: Task<Void, Never>?

    /// Random secret the hooks must send; generated once and kept in settings.
    var token: String {
        if Defaults[.claudeHookToken].isEmpty {
            Defaults[.claudeHookToken] = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        return Defaults[.claudeHookToken]
    }

    // MARK: Listener

    func start() {
        guard listener == nil, Defaults[.claudeCodeBridge] else { return }
        let parameters = NWParameters.tcp
        // Loopback only: nothing off this Mac can reach it
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else {
            print("[ClaudeCodeBridge] Could not open port \(Self.port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            MainActor.assumeIsolated { self?.receive(on: connection, buffer: Data()) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        askingProject = nil
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HookHTTPRequest.parse(buffer) {
                case .complete(let request):
                    self.handle(request, on: connection)
                case .incomplete where !isComplete && error == nil && buffer.count < 1_000_000:
                    self.receive(on: connection, buffer: buffer)
                default:
                    Self.reply(Data(), status: "400 Bad Request", on: connection)
                }
            }
        }
    }

    private func handle(_ request: HookHTTPRequest, on connection: NWConnection) {
        guard request.method == "POST",
              request.headers["x-stickynotch-token"] == token,
              let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        else {
            return Self.reply(Data(), status: "403 Forbidden", on: connection)
        }
        let project = ((json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "Claude Code"
        let sessionID = json["session_id"] as? String ?? project

        switch request.path {
        case "/claude/PermissionRequest":
            Self.reply(Data(), on: connection) // no decision: Claude Code asks in the terminal right away
            withAnimation(Self.spring) { running[sessionID] = running[sessionID] ?? (project, Date()) } // asking implies working
            showAsking(project)

        case "/claude/UserPromptSubmit":
            Self.reply(Data(), on: connection) // empty = don't touch the prompt
            withAnimation(Self.spring) { running[sessionID] = (project, Date()) }
            acknowledgeAsking()

        case "/claude/Stop", "/claude/StopFailure":
            Self.reply(Data(), on: connection)
            withAnimation(Self.spring) { running[sessionID] = nil }
            acknowledgeAsking()
            showFinished(project)

        case "/claude/SessionEnd":
            Self.reply(Data(), on: connection)
            withAnimation(Self.spring) { running[sessionID] = nil }

        default:
            Self.reply(Data(), status: "404 Not Found", on: connection)
        }
    }

    // MARK: Notices

    private func showAsking(_ project: String) {
        withAnimation(Self.spring) { askingProject = project }
        askingTask?.cancel()
        askingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            acknowledgeAsking()
        }
    }

    func acknowledgeAsking() {
        guard askingProject != nil else { return }
        askingTask?.cancel()
        withAnimation(Self.spring) { askingProject = nil }
    }

    private func showFinished(_ project: String) {
        withAnimation(Self.spring) { finishedProject = project }
        finishedTask?.cancel()
        finishedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            acknowledgeFinished()
        }
    }

    /// Opening the notch counts as "seen".
    func acknowledgeFinished() {
        guard finishedProject != nil else { return }
        finishedTask?.cancel()
        withAnimation(Self.spring) { finishedProject = nil }
    }

    // MARK: Helpers

    nonisolated private static func reply(_ body: Data, status: String = "200 OK", on connection: NWConnection) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Connecting Claude Code (~/.claude/settings.json)

    nonisolated static let hookURLPrefix = "http://127.0.0.1:\(port)/claude/"

    /// StickyNotch's hook entry per Claude Code event.
    private var ourHooks: [String: [String: Any]] {
        func hook(_ event: String, timeout: Int) -> [String: Any] {
            ["hooks": [["type": "http", "url": Self.hookURLPrefix + event,
                        "timeout": timeout, "headers": ["X-StickyNotch-Token": token]]]]
        }
        return [
            "PermissionRequest": hook("PermissionRequest", timeout: 5),
            "UserPromptSubmit": hook("UserPromptSubmit", timeout: 5),
            "Stop": hook("Stop", timeout: 5),
            "StopFailure": hook("StopFailure", timeout: 5),
            "SessionEnd": hook("SessionEnd", timeout: 5),
        ]
    }

    enum ConnectError: LocalizedError {
        case claudeNotFound, unreadableSettings

        var errorDescription: String? {
            switch self {
            case .claudeNotFound: "Claude Code isn't set up on this Mac (no ~/.claude folder). Run claude once, then try again."
            case .unreadableSettings: "~/.claude/settings.json isn't valid JSON, so StickyNotch left it alone."
            }
        }
    }

    /// Real home folder; inside the sandbox homeDirectoryForCurrentUser points at the app container.
    private static var claudeSettingsURL: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".claude/settings.json")
    }

    var isConnected: Bool {
        guard let settings = try? Self.readSettings() else { return false }
        return Self.containsOurHooks(settings["hooks"] as? [String: Any] ?? [:])
    }

    /// Adds (or refreshes) StickyNotch's hooks, leaving everything else in the file untouched.
    /// The original file is backed up once as settings.json.before-stickynotch.
    func connect() throws {
        let url = Self.claudeSettingsURL
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path) else { throw ConnectError.claudeNotFound }
        var settings = try Self.readSettings()
        var hooks = Self.removingOurHooks(settings["hooks"] as? [String: Any] ?? [:])
        for (event, entry) in ourHooks {
            hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
        }
        settings["hooks"] = hooks
        let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.before-stickynotch")
        if FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: url, to: backup)
        }
        try Self.write(settings)
    }

    /// Removes only StickyNotch's hooks.
    func disconnect() throws {
        guard FileManager.default.fileExists(atPath: Self.claudeSettingsURL.path) else { return }
        var settings = try Self.readSettings()
        let hooks = Self.removingOurHooks(settings["hooks"] as? [String: Any] ?? [:])
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try Self.write(settings)
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsURL), !data.isEmpty else { return [:] } // no file yet
        guard let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ConnectError.unreadableSettings
        }
        return settings
    }

    private static func write(_ settings: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        data.append(Data("\n".utf8))
        try data.write(to: claudeSettingsURL, options: .atomic)
    }

    /// Drops hook entries that point at StickyNotch, and events left empty by that. Leaves everything else as is.
    nonisolated static func removingOurHooks(_ hooks: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            let kept = entries.filter { !isOurs($0) }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    nonisolated static func containsOurHooks(_ hooks: [String: Any]) -> Bool {
        hooks.values.contains { ($0 as? [[String: Any]])?.contains(where: isOurs) ?? false }
    }

    nonisolated private static func isOurs(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["url"] as? String)?.hasPrefix(hookURLPrefix) == true }
    }
}

// MARK: - Minimal HTTP request parsing (one request per connection)

struct HookHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String] // lowercased names
    let body: Data

    enum ParseResult {
        case complete(HookHTTPRequest)
        case incomplete
        case invalid
    }

    static func parse(_ data: Data) -> ParseResult {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return .incomplete }
        return .complete(HookHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                                         headers: headers, body: Data(body.prefix(length))))
    }
}

// MARK: - Notch views

/// "? Claude  [notch]  project" while Claude waits for your answer in the terminal.
struct AgentAskingActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    let project: String

    var body: some View {
        HStack(spacing: 0) {
            Label("Claude", systemImage: "questionmark.bubble.fill")
                .foregroundStyle(.orange)
                .help("Claude asked you a question in the terminal")
                .frame(width: 90, alignment: .leading)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width + 10)
            Text(project)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

/// "✓ Claude  [notch]  project" for a few seconds after a turn finishes.
struct AgentFinishedActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    let project: String

    var body: some View {
        HStack(spacing: 0) {
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 90, alignment: .leading)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width + 10)
            Text(project)
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}

/// "◌ Claude  [notch]  project" while a prompt is still being worked on.
struct AgentRunningActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    let project: String

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.orange)
                Text("Claude")
                    .foregroundStyle(.orange)
            }
            .frame(width: 90, alignment: .leading)
            Rectangle().fill(.black).frame(width: vm.closedNotchSize.width + 10)
            Text(project)
                .foregroundStyle(.gray)
                .lineLimit(1)
                .frame(width: 90, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .frame(height: vm.effectiveClosedNotchHeight)
    }
}
