import Darwin
import Foundation

/// Runs Qwen3-ASR-1.7B through MLX in a long-lived local Python worker.
///
/// The worker is started with `uv`, keeps the model loaded between recordings,
/// and exchanges one JSON line per request over stdin/stdout. Audio is handed
/// over as a private temporary file of 16 kHz mono float32 samples that is
/// deleted after every request.
final class Qwen3ASRWorker: @unchecked Sendable {
    static let modelVersion = "qwen3-asr-1.7b"
    static let modelID = "Qwen/Qwen3-ASR-1.7B"
    static let packageRequirement = "mlx-qwen3-asr==0.4.4"
    static let pythonVersion = "3.12"
    static let sampleRate = 16_000

    private static let workerScript = #"""
import json, os, sys

protocol = os.fdopen(os.dup(1), "w", buffering=1)
os.dup2(2, 1)
sys.stdout = sys.stderr

def send(message):
    protocol.write(json.dumps(message) + "\n")
    protocol.flush()

try:
    import numpy as np
    from mlx_qwen3_asr import Session
    session = Session(model=sys.argv[1])
    session.transcribe((np.zeros(int(sys.argv[2]), dtype=np.float32), int(sys.argv[2])))
except Exception as error:
    send({"error": f"{type(error).__name__}: {error}"})
    sys.exit(1)

send({"ready": True})
for line in sys.stdin:
    try:
        request = json.loads(line)
        audio = np.fromfile(request["path"], dtype="<f4")
        result = session.transcribe((audio, int(sys.argv[2])))
        send({"text": result.text or "", "truncated": bool(getattr(result, "truncated", False))})
    except Exception as error:
        send({"error": f"{type(error).__name__}: {error}"})
"""#

    private let queue = DispatchQueue(label: "fluid-push-to-talk.qwen3-asr")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()

    func start() async throws {
        try await run {
            try self.startLocked()
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await run {
            try self.transcribeLocked(samples: samples)
        }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func startLocked() throws {
        if process?.isRunning == true {
            return
        }
        stopLocked()
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = try Self.resolveUV()
        process.arguments = [
            "run", "--quiet", "--no-project",
            "--python", Self.pythonVersion,
            "--with", Self.packageRequirement,
            "python", "-c", Self.workerScript,
            Self.modelID, String(Self.sampleRate),
        ]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        try process.run()

        self.process = process
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading

        let reply = try readReply()
        if let error = reply["error"] as? String {
            stopLocked()
            throw CliError.invalidValue("Qwen3-ASR worker failed to start: \(error)")
        }
        guard reply["ready"] as? Bool == true else {
            stopLocked()
            throw CliError.invalidValue("Qwen3-ASR worker sent an unexpected startup reply")
        }
    }

    private func transcribeLocked(samples: [Float]) throws -> String {
        try startLocked()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fluid_ptt_qwen3_\(UUID().uuidString)")
            .appendingPathExtension("f32")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let audio = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: audio,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CliError.invalidValue("Qwen3-ASR could not write temporary audio")
        }

        var request = try JSONSerialization.data(withJSONObject: ["path": url.path])
        request.append(0x0A)
        do {
            try input?.write(contentsOf: request)
        } catch {
            stopLocked()
            throw CliError.invalidValue("Qwen3-ASR worker is not accepting audio: \(error)")
        }

        let reply = try readReply()
        if let error = reply["error"] as? String {
            throw CliError.invalidValue("Qwen3-ASR failed: \(error)")
        }
        if reply["truncated"] as? Bool == true {
            fputs("Qwen3-ASR warning: transcript reached the token limit and may be incomplete\n", stderr)
        }
        return (reply["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readReply() throws -> [String: Any] {
        guard let output else {
            throw CliError.invalidValue("Qwen3-ASR worker is not running")
        }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CliError.invalidValue("Qwen3-ASR worker sent an invalid reply")
                }
                return reply
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else {
                stopLocked()
                throw CliError.invalidValue("Qwen3-ASR worker exited unexpectedly")
            }
            buffer.append(chunk)
        }
    }

    private func stopLocked() {
        try? input?.close()
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
    }

    private static func resolveUV() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = ["\(home)/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/uv" }
        }
        guard let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw CliError.invalidValue(
                "model_version \(modelVersion) needs uv to run the local MLX worker. Install it from https://docs.astral.sh/uv/"
            )
        }
        return URL(fileURLWithPath: match)
    }
}
