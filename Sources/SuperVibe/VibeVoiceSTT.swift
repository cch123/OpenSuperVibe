import Foundation

final class VibeVoiceSTT {
    struct Model {
        let name: String
        let id: String
    }

    static let availableModels: [Model] = [
        .init(name: "VibeVoice-ASR 4bit (~5GB)", id: "mlx-community/VibeVoice-ASR-4bit"),
        .init(name: "VibeVoice-ASR bf16 (~18GB)", id: "mlx-community/VibeVoice-ASR-bf16"),
    ]

    private(set) var currentModel: Model = availableModels[0]
    private var serverProcess: Process?
    private var serverStdin: FileHandle?
    private var serverStdout: FileHandle?
    private(set) var ready = false

    func isAvailable() -> Bool {
        guard let python = findPython() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-c", "import mlx_audio; print('ok')"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func selectModel(_ model: Model) {
        if model.id != currentModel.id {
            shutdown()
            currentModel = model
        }
    }

    /// Start the persistent Python server (model loaded once).
    func warmup() throws {
        guard serverProcess == nil else { return }
        guard let python = findPython() else {
            throw VibeVoiceError.notFound("mlx-audio not found. Run: pipx install mlx-audio")
        }
        guard let script = findScript() else {
            throw VibeVoiceError.notFound("vibevoice_server.py not found")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, currentModel.id]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/stderr") ?? FileHandle.nullDevice

        try process.run()
        serverProcess = process
        serverStdin = stdinPipe.fileHandleForWriting
        serverStdout = stdoutPipe.fileHandleForReading

        log("[VibeVoice] Waiting for model to load...")
        if let line = readLine(from: serverStdout!),
           line.trimmingCharacters(in: .whitespacesAndNewlines) == "READY" {
            ready = true
            log("[VibeVoice] Server ready")
        } else {
            throw VibeVoiceError.notFound("VibeVoice server failed to start")
        }
    }

    func transcribe(wavPath: String) throws -> String {
        if serverProcess == nil {
            try warmup()
        }

        guard ready, let stdin = serverStdin, let stdout = serverStdout else {
            throw VibeVoiceError.failed("VibeVoice server not ready")
        }

        let request = wavPath + "\n"
        stdin.write(request.data(using: .utf8)!)

        guard let responseLine = readLine(from: stdout) else {
            throw VibeVoiceError.failed("No response from VibeVoice server")
        }

        guard let data = responseLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw VibeVoiceError.failed("Invalid response: \(responseLine)")
        }

        if let ok = json["ok"] as? Bool, ok, let text = json["text"] as? String {
            return text
        } else {
            let error = json["error"] as? String ?? "unknown error"
            throw VibeVoiceError.failed("VibeVoice: \(error)")
        }
    }

    func shutdown() {
        serverStdin?.closeFile()
        serverProcess?.terminate()
        serverProcess = nil
        serverStdin = nil
        serverStdout = nil
        ready = false
    }

    deinit { shutdown() }

    // MARK: - Private

    private func readLine(from handle: FileHandle) -> String? {
        var buffer = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            if byte.first == UInt8(ascii: "\n") {
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(byte)
        }
    }

    private func findPython() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pipxPython = "\(home)/.local/pipx/venvs/mlx-audio/bin/python3"
        if FileManager.default.isExecutableFile(atPath: pipxPython) {
            return pipxPython
        }
        return nil
    }

    private func findScript() -> String? {
        // SPM resource bundle
        if let url = Bundle.module.url(forResource: "vibevoice_server", withExtension: "py", subdirectory: "Resources") {
            return url.path
        }
        // Fallback: development path
        let devPath = FileManager.default.currentDirectoryPath + "/Sources/SuperVibe/Resources/vibevoice_server.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }
        return nil
    }

    enum VibeVoiceError: LocalizedError {
        case notFound(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let msg), .failed(let msg):
                return msg
            }
        }
    }
}
