//
//  ClaudeCodeBridge.swift
//  StickyNotch
//
//  Shows Claude Code permission requests and finished turns in the notch.
//  Claude Code's "http" hooks POST to a tiny loopback-only listener here:
//    POST /claude/PermissionRequest  → held open until you click Allow / Deny (or it times out)
//    POST /claude/Stop               → "Claude finished" notice
//  Every request must carry the X-StickyNotch-Token header. Anything else (no app running, wrong token,
//  timeout) answers with an empty 200, which Claude Code treats as "no decision" → normal terminal prompt.
//

import AppKit
import Defaults
import Network
import SwiftUI

// MARK: - State shown in the notch

struct AgentPermission: Identifiable {
    let id: UUID
    let tool: String
    let detail: String
    let project: String
    /// Claude Code's own suggested rule(s) for "Always allow" (passed back as updatedPermissions)
    let suggestions: Any?
    let respond: (Data) -> Void
}

@MainActor
final class ClaudeCodeBridge: ObservableObject {
    static let shared = ClaudeCodeBridge()

    @Published private(set) var pending: [AgentPermission] = []
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
    /// Unanswered requests fall back to the terminal prompt after this long.
    /// ponytail: fixed; make it a setting if 30s feels wrong
    static let decisionTimeout: TimeInterval = 30

    private var listener: NWListener?
    private var finishedTask: Task<Void, Never>?

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
        pending.forEach { $0.respond(Data()) } // let waiting sessions fall back to the terminal
        pending.removeAll()
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
            let tool = json["tool_name"] as? String ?? "Tool"
            let detail = Self.describe(tool: tool, input: json["tool_input"] as? [String: Any] ?? [:])
            let id = UUID()
            var answered = false
            let item = AgentPermission(id: id, tool: tool, detail: detail, project: project,
                                       suggestions: json["permission_suggestions"]) { [weak self] body in
                guard !answered else { return }
                answered = true
                Self.reply(body, on: connection)
                MainActor.assumeIsolated { withAnimation(Self.spring) { self?.pending.removeAll { $0.id == id } } }
            }
            withAnimation(Self.spring) {
                pending.append(item)
                running[sessionID] = running[sessionID] ?? (project, Date()) // asking implies working
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.decisionTimeout))
                item.respond(Data()) // no answer → Claude Code shows its normal prompt
            }

        case "/claude/UserPromptSubmit":
            Self.reply(Data(), on: connection) // empty = don't touch the prompt
            withAnimation(Self.spring) { running[sessionID] = (project, Date()) }

        case "/claude/Stop", "/claude/StopFailure":
            Self.reply(Data(), on: connection)
            withAnimation(Self.spring) { running[sessionID] = nil }
            showFinished(project)

        case "/claude/SessionEnd":
            Self.reply(Data(), on: connection)
            withAnimation(Self.spring) { running[sessionID] = nil }

        default:
            Self.reply(Data(), status: "404 Not Found", on: connection)
        }
    }

    // MARK: Decisions

    func allow(_ item: AgentPermission, always: Bool = false) {
        var decision: [String: Any] = ["behavior": "allow"]
        if always, let suggestions = item.suggestions { decision["updatedPermissions"] = suggestions }
        item.respond(Self.decisionBody(decision))
    }

    func deny(_ item: AgentPermission) {
        item.respond(Self.decisionBody(["behavior": "deny", "message": "Denied from StickyNotch"]))
    }

    private static func decisionBody(_ decision: [String: Any]) -> Data {
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
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

    /// One readable line for the request: the command, file name, URL, …
    nonisolated static func describe(tool: String, input: [String: Any]) -> String {
        let text: String
        if let command = input["command"] as? String {
            text = command
        } else if let path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String {
            text = URL(fileURLWithPath: path).lastPathComponent
        } else if let url = input["url"] as? String {
            text = url
        } else if let first = input.values.compactMap({ $0 as? String }).first {
            text = first
        } else {
            text = ""
        }
        let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 120 ? String(oneLine.prefix(120)) + "…" : oneLine
    }

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
            "PermissionRequest": hook("PermissionRequest", timeout: Int(Self.decisionTimeout) + 5),
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

/// Closed notch grows into a small strip: who's asking, what, and Allow / Deny / Always.
struct AgentPermissionStrip: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var bridge = ClaudeCodeBridge.shared
    let item: AgentPermission

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                Label("Claude", systemImage: "sparkle")
                    .foregroundStyle(.orange)
                    .frame(width: 100, alignment: .leading)
                Rectangle().fill(.black).frame(width: vm.closedNotchSize.width)
                Text(bridge.pending.count > 1 ? "\(item.project) +\(bridge.pending.count - 1)" : item.project)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(height: vm.effectiveClosedNotchHeight)

            HStack(spacing: 6) {
                Text(item.tool)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(item.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.detail)
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                stripButton("Deny", color: .white.opacity(0.12)) { bridge.deny(item) }
                if item.suggestions != nil {
                    stripButton("Always allow", color: .white.opacity(0.12)) { bridge.allow(item, always: true) }
                }
                stripButton("Allow", color: .green.opacity(0.85)) { bridge.allow(item) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(width: vm.closedNotchSize.width + 200)
    }

    private func stripButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Capsule().fill(color))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
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
