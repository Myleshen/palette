import Foundation
import PaletteCore
import PalettePlatform

private final class LineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<newline]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }
}

/// An out-of-process command provider speaking the NDJSON protocol from
/// PROVIDERS.md. It is started lazily, queries are serialized, and a crash is
/// isolated from the host.
public actor ExternalProvider: PaletteProvider {
    private struct ActiveQuery {
        var id: String
        var items: [PaletteItem]
        var continuation: CheckedContinuation<[PaletteItem], Error>
    }

    public nonisolated let descriptor: ProviderDescriptor
    private let manifest: ProviderManifest
    private let host: HostBridge
    private var process: Process?
    private var input: FileHandle?
    private var active: ActiveQuery?
    private var timeoutTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var nextSequence = 1
    private var crashedAt: Date?
    private var restartDelay: TimeInterval = 0
    private var shuttingDown = false
    private let writeQueue = DispatchQueue(label: "dev.myleshen.palette.provider-write")
    private var lineContinuation: AsyncStream<String>.Continuation?
    private var lineTask: Task<Void, Never>?

    public init(manifest: ProviderManifest, host: HostBridge) {
        self.manifest = manifest
        self.host = host
        self.descriptor = manifest.descriptor
    }

    public func search(_ request: SearchRequest) async throws -> [PaletteItem] {
        try Task.checkCancellation()
        if let active {
            cancelQuery(id: active.id)
        }
        try await ensureRunning()
        try Task.checkCancellation()

        let id = "q\(nextSequence)"
        nextSequence += 1
        let timeout = TimeInterval(manifest.timeoutMs) / 1_000

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                active = ActiveQuery(id: id, items: [], continuation: continuation)
                idleTask?.cancel()
                timeoutTask?.cancel()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await self?.timeOut(id: id)
                }
                send([
                    "type": "query",
                    "id": id,
                    "text": request.text,
                    "terms": request.terms,
                    "limit": request.limit,
                    "trigger": manifest.trigger ?? "",
                ])
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    public func activate(_ item: PaletteItem, action: PaletteAction) async throws {
        try await ensureRunning()
        let id = "a\(nextSequence)"
        nextSequence += 1
        send([
            "type": "activate",
            "id": id,
            "item_id": item.id,
            "action_id": action.id,
        ])
    }

    public func shutdown() async {
        shuttingDown = true
        idleTask?.cancel()
        timeoutTask?.cancel()
        send(["type": "shutdown"])
        if let process, process.isRunning {
            try? await Task.sleep(nanoseconds: 200_000_000)
            process.terminate()
        }
        process = nil
        input = nil
        stopLineStream()
    }

    private func stopLineStream() {
        lineContinuation?.finish()
        lineContinuation = nil
        lineTask?.cancel()
        lineTask = nil
    }

    // MARK: - Process lifecycle

    private func ensureRunning() async throws {
        if let process, process.isRunning { return }
        stopLineStream()

        if let crashedAt, restartDelay > 0 {
            let elapsed = Date().timeIntervalSince(crashedAt)
            if elapsed < restartDelay {
                try? await Task.sleep(nanoseconds: UInt64((restartDelay - elapsed) * 1_000_000_000))
            }
        }

        guard !manifest.command.isEmpty else {
            throw ProviderError.failed("Provider '\(manifest.id)' has no command")
        }

        var arguments = manifest.command
        let command = arguments[0]
        if command.contains("/") {
            if !command.hasPrefix("/") {
                arguments[0] = manifest.directory.appendingPathComponent(command).path
            }
        } else if let resolved = ToolLocator.shared.path(for: command) {
            arguments[0] = resolved
        } else {
            throw ProviderError.toolMissing(command)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = manifest.directory
        var environment = ProcessInfo.processInfo.environment
        environment["PALETTE_PROVIDER_ID"] = manifest.id
        environment["PALETTE_CONFIG_DIR"] = PalettePaths.resolve().configDir.path
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let (lines, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        lineContinuation = continuation
        lineTask = Task { [weak self] in
            for await line in lines {
                guard let self else { break }
                await self.receive(line)
            }
        }
        let reader = LineReader { line in
            continuation.yield(line)
        }
        let providerID = manifest.id
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            reader.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                Log.shared.warn("\(line)", source: "provider:\(providerID)")
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            let pid = process.processIdentifier
            let status = process.terminationStatus
            Task { await self.processExited(pid: pid, status: status) }
        }

        do {
            try process.run()
        } catch {
            throw ProviderError.failed("Could not start '\(arguments[0])': \(error.localizedDescription)")
        }

        self.process = process
        self.input = stdinPipe.fileHandleForWriting
        restartDelay = 0
        crashedAt = nil
        send(["type": "init", "api_version": 1, "config": [:] as [String: Any]])
        scheduleIdle()
    }

    private func processExited(pid: Int32, status: Int32) async {
        // Ignore a late exit from a process we already replaced or killed.
        guard let current = process, current.processIdentifier == pid else { return }
        input = nil
        process = nil
        stopLineStream()
        if let active {
            self.active = nil
            timeoutTask?.cancel()
            active.continuation.resume(throwing: ProviderError.failed("Provider '\(manifest.id)' exited with status \(status)"))
        }
        if !shuttingDown {
            crashedAt = Date()
            restartDelay = restartDelay == 0 ? 1 : min(30, restartDelay * 2)
            Log.shared.warn("Provider '\(manifest.id)' exited with status \(status)", source: "providers")
        }
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        guard active == nil else { return }
        let seconds = manifest.idleTimeoutS
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.idleShutdown()
        }
    }

    private func idleShutdown() {
        guard active == nil, let process, process.isRunning else { return }
        send(["type": "shutdown"])
        process.terminate()
        self.process = nil
        input = nil
        stopLineStream()
    }

    // MARK: - Protocol

    private func receive(_ line: String) async {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            Log.shared.warn("Invalid provider output: \(line.prefix(200))", source: "provider:\(manifest.id)")
            return
        }

        switch type {
        case "results":
            guard let id = object["id"] as? String, id == active?.id,
                  let rawItems = object["items"] as? [[String: Any]] else { return }
            let items = rawItems.compactMap { Self.item(from: $0, manifest: manifest) }
            active?.items.append(contentsOf: items)

        case "done":
            guard let id = object["id"] as? String, id == active?.id, let active else { return }
            self.active = nil
            timeoutTask?.cancel()
            restartDelay = 0
            active.continuation.resume(returning: active.items)
            scheduleIdle()

        case "error":
            guard let id = object["id"] as? String, id == active?.id, let active else { return }
            self.active = nil
            timeoutTask?.cancel()
            let message = object["message"] as? String ?? "Provider error"
            active.continuation.resume(throwing: ProviderError.failed(message))
            scheduleIdle()

        case "prompt":
            guard let id = object["id"] as? String else { return }
            let kind = PromptKind(rawValue: object["kind"] as? String ?? "text") ?? .text
            let title = object["title"] as? String ?? "Input"
            let placeholder = object["placeholder"] as? String
            let bridge = host
            Task { [weak self] in
                let value = await bridge.prompt(kind: kind, title: title, placeholder: placeholder)
                await self?.sendPromptResult(id: id, value: value)
            }

        case "notify":
            if let message = object["message"] as? String {
                await host.notify(message)
            }

        case "copy":
            if let text = object["text"] as? String {
                let concealed = object["concealed"] as? Bool ?? false
                let clear = object["clear_after_ms"] as? Int
                await host.copyToClipboard(text, concealed: concealed, clearAfterMs: clear)
            }

        default:
            break
        }
    }

    private func sendPromptResult(id: String, value: String?) {
        send(["type": "prompt_result", "id": id, "value": value ?? ""])
    }

    private func send(_ object: [String: Any]) {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let payload = Data(line.utf8)
        let providerID = manifest.id
        writeQueue.async {
            do {
                try input.write(contentsOf: payload)
            } catch {
                Log.shared.error("Provider write failed: \(error.localizedDescription)", source: "provider:\(providerID)")
            }
        }
    }

    private func cancelQuery(id: String) {
        guard let active, active.id == id else { return }
        self.active = nil
        timeoutTask?.cancel()
        active.continuation.resume(throwing: ProviderError.cancelled)
        send(["type": "cancel", "id": id])
        scheduleIdle()
    }

    private func cancel(id: String) {
        cancelQuery(id: id)
    }

    private func timeOut(id: String) {
        guard let active, active.id == id else { return }
        self.active = nil
        timeoutTask?.cancel()
        active.continuation.resume(throwing: ProviderError.timedOut)
        send(["type": "cancel", "id": id])
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
        scheduleIdle()
    }

    // MARK: - Wire mapping

    private static func item(from object: [String: Any], manifest: ProviderManifest) -> PaletteItem? {
        guard let id = object["id"] as? String, !id.isEmpty else { return nil }
        let title = object["title"] as? String ?? id
        let icon = icon(from: object["icon"]) ?? defaultIcon(manifest.icon)
        let actions = (object["actions"] as? [[String: Any]] ?? []).compactMap { action(from: $0) }
        return PaletteItem(
            id: id,
            title: title,
            subtitle: object["subtitle"] as? String,
            icon: icon,
            badge: object["badge"] as? String,
            group: object["group"] as? String,
            accent: object["accent"] as? String,
            score: number(object["score"]) ?? 0,
            actions: actions,
            providerID: manifest.id,
            providerName: manifest.name
        )
    }

    private static func action(from object: [String: Any]) -> PaletteAction? {
        guard let id = object["id"] as? String else { return nil }
        let kind = ActionKind(rawValue: object["kind"] as? String ?? "custom") ?? .custom
        let value = actionValue(object["value"])
        return PaletteAction(
            id: id,
            title: object["title"] as? String ?? id,
            kind: kind,
            value: value,
            concealed: object["concealed"] as? Bool ?? false,
            clearAfterMs: object["clear_after_ms"] as? Int,
            shortcut: object["shortcut"] as? String
        )
    }

    private static func actionValue(_ raw: Any?) -> ActionValue {
        switch raw {
        case let string as String:
            return .text(string)
        case let array as [Any]:
            return .list(array.compactMap { $0 as? String })
        case let dictionary as [String: Any]:
            var result: [String: String] = [:]
            for (key, value) in dictionary {
                if let string = value as? String {
                    result[key] = string
                } else if let number = value as? NSNumber {
                    result[key] = number.stringValue
                }
            }
            return .object(result)
        default:
            return .none
        }
    }

    private static func icon(from raw: Any?) -> IconSpec? {
        guard let dictionary = raw as? [String: Any],
              let type = dictionary["type"] as? String,
              let value = dictionary["value"] as? String else { return nil }
        switch type {
        case "symbol": return .symbol(value)
        case "file": return .file(value)
        case "url": return .url(value)
        case "base64": return .base64(value)
        default: return nil
        }
    }

    private static func defaultIcon(_ raw: String?) -> IconSpec? {
        guard let raw else { return nil }
        if raw.hasPrefix("symbol:") { return .symbol(String(raw.dropFirst(7))) }
        if raw.hasPrefix("file:") { return .file(String(raw.dropFirst(5))) }
        if raw.hasPrefix("http") { return .url(raw) }
        return .symbol(raw)
    }

    private static func number(_ raw: Any?) -> Double? {
        if let double = raw as? Double { return double }
        if let int = raw as? Int { return Double(int) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }
}
