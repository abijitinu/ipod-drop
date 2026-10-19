import Foundation
import Observation

/// Runs the Python `ipod_engine` helper and talks to it with line-delimited JSON-RPC.
/// The engine is the only process that writes to the iPod.
@Observable
final class EngineClient {
    enum State: Equatable {
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .starting
    /// Server-pushed events: method name and raw JSON params.
    var onEvent: ((String, Data) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var restarts = 0
    private var stopping = false

    static let logURL: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/iPodDrop", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "engine.log")
    }()

    func start() {
        stopping = false
        guard let launch = Self.launchConfiguration() else {
            state = .failed("The iPod engine is missing from this copy of iPod Drop.")
            return
        }
        let process = Process()
        process.executableURL = launch.python
        process.arguments = ["-m", "ipod_engine"]
        process.currentDirectoryURL = launch.root
        var env = ProcessInfo.processInfo.environment
        env["QT_QPA_PLATFORM"] = "offscreen"
        env["PYTHONPATH"] = launch.root.path
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        // ffmpeg/ffprobe come from Homebrew; Finder-launched apps don't inherit the shell PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        process.standardError = (try? FileHandle(forWritingTo: Self.logURL)) ?? FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.terminated(status: status) }
        }
        do {
            try process.run()
        } catch {
            state = .failed("Couldn't start the iPod engine: \(error.localizedDescription)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        state = .starting

        let reader = stdout.fileHandleForReading
        Task.detached { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    await self?.receive(line)
                }
            } catch {}
        }
    }

    func stop() {
        stopping = true
        try? input?.close()  // the engine exits when its stdin closes
        input = nil
        if let process, process.isRunning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// Call a method and decode its result.
    func call<T: Decodable>(_ method: String, _ params: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await raw(method, params)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw EngineError.decoding("\(method): \(error)")
        }
    }

    /// Call a method whose result is not needed.
    func send(_ method: String, _ params: [String: Any] = [:]) async throws {
        _ = try await raw(method, params)
    }

    private func raw(_ method: String, _ params: [String: Any]) async throws -> Data {
        guard let input else { throw EngineError.notRunning }
        nextID += 1
        let id = nextID
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try input.write(contentsOf: data)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: EngineError.notRunning)
            }
        }
    }

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }

        if let id = object["id"] as? Int {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = object["error"] as? [String: Any] {
                continuation.resume(throwing: EngineError.remote(error["message"] as? String ?? "Unknown error"))
            } else {
                let result = object["result"] ?? NSNull()
                let encoded = (try? JSONSerialization.data(withJSONObject: result, options: .fragmentsAllowed)) ?? Data("null".utf8)
                continuation.resume(returning: encoded)
            }
            return
        }
        guard let method = object["method"] as? String else { return }
        if method == "engine.ready" {
            state = .running
            restarts = 0
        }
        let params = object["params"] ?? [String: Any]()
        let encoded = (try? JSONSerialization.data(withJSONObject: params)) ?? Data("{}".utf8)
        onEvent?(method, encoded)
    }

    private func terminated(status: Int32) {
        process = nil
        input = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: EngineError.notRunning)
        }
        pending.removeAll()
        guard !stopping else { return }
        restarts += 1
        if restarts > 3 {
            state = .failed("The iPod engine keeps stopping (exit \(status)). See \(Self.logURL.path).")
            return
        }
        state = .starting
        onEvent?("engine.restarting", Data("{}".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start() }
    }

    private struct Launch {
        let python: URL
        let root: URL
    }

    /// A bundled engine (Contents/Resources/engine) wins; otherwise use the dev checkout's .venv.
    private static func launchConfiguration() -> Launch? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let engine = resources.appending(path: "engine", directoryHint: .isDirectory)
            let python = engine.appending(path: "python/bin/python3")
            if fm.isExecutableFile(atPath: python.path) {
                return Launch(python: python, root: engine.appending(path: "app", directoryHint: .isDirectory))
            }
        }
        if let rootPath = Bundle.main.object(forInfoDictionaryKey: "IPDEngineRoot") as? String, !rootPath.isEmpty {
            let root = URL(filePath: rootPath, directoryHint: .isDirectory)
            let python = root.appending(path: ".venv/bin/python")
            if fm.isExecutableFile(atPath: python.path) {
                return Launch(python: python, root: root)
            }
        }
        return nil
    }
}

enum EngineError: LocalizedError {
    case remote(String)
    case notRunning
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .remote(let message): message
        case .notRunning: "The iPod engine isn't running."
        case .decoding(let detail): "Unexpected reply from the iPod engine (\(detail))."
        }
    }
}
