import Foundation

// Only host configuration/logging are stubbed; transport and diagnostics are production sources.
enum AppConfig { static let repositoryRootURL = URL(fileURLWithPath: "/unused-test-root") }
final class LogCapture: @unchecked Sendable {
    static let shared = LogCapture()
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ text: String) { lock.withLock { lines.append(text) } }
    var joined: String { lock.withLock { lines.joined(separator: "\n") } }
}
func log(_ text: String) { LogCapture.shared.append(text) }

func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw HarnessFailure(message: message) }
}
struct HarnessFailure: Error { let message: String }

final class HarnessURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var last: URLRequest?
    nonisolated(unsafe) private static var failure: URLError.Code?
    static func respond(_ text: String, status: Int = 200) {
        lock.withLock { body = Data(text.utf8); self.status = status; last = nil; failure = nil }
    }
    static func fail(_ code: URLError.Code) { lock.withLock { failure = code } }
    static var captured: URLRequest? { lock.withLock { last } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (data, code, failure) = Self.lock.withLock { Self.last = request; return (Self.body, Self.status, Self.failure) }
        if let failure {
            client?.urlProtocol(self, didFailWithError: URLError(failure, userInfo: [NSLocalizedDescriptionKey: "sensitive-canary"]))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct SubscriptionClientHarness {
    static func main() async {
        do {
            try await openAI()
            print("PASS OpenAI default and configured model payload/display/diagnostics")
            try await hermes()
            print("PASS Hermes stdin-only request, provider isolation, doctor and image ordering")
            try await anthropic()
            print("PASS Anthropic native payload, images, timeout, refusal/truncation/malformed/HTTP errors")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HarnessURLProtocol.self]
        return URLSession(configuration: config)
    }
    static func jsonRequest() throws -> [String: Any] {
        guard let request = HarnessURLProtocol.captured else { throw HarnessFailure(message: "no request") }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        }
        guard let data = body,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarnessFailure(message: "missing request body")
        }
        return json
    }
    static var root: URL { URL(fileURLWithPath: CommandLine.arguments[1]) }
    static func script(_ body: String) throws -> URL {
        let file = root.appendingPathComponent("launcher-\(UUID().uuidString).sh")
        try Data(("#!/bin/bash\n" + body).utf8).write(to: file)
        return file
    }
    static func images() throws -> [URL] {
        try (0..<5).map { index in
            let url = root.appendingPathComponent("image-\(index).png")
            try Data([137,80,78,71,13,10,26,10,UInt8(index)]).write(to: url)
            return url
        }
    }
    static func mustFail(_ name: String, _ operation: () async throws -> String) async throws {
        do {
            _ = try await operation()
        } catch {
            try check(!error.localizedDescription.contains("sensitive-canary"), "unsafe error: \(name)")
            return
        }
        throw HarnessFailure(message: "expected failure: \(name)")
    }
    static func hermes() async throws {
        let launcher = try script("""
        exec /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); assert len(sys.argv)==1; assert r["provider"] in ("openai-codex","anthropic"); assert r["model"]=="test-model"; assert r["reasoning_effort"]=="low"; assert r["timeout_seconds"]==3; print(json.dumps({"ok":True,"detail":"ready"} if r["action"]=="doctor" else {"ok":True,"text":str(len(r["images"]))+":"+",".join(r["images"])}))'
        """)
        let urls = try images()
        for provider in ["openai-codex", "anthropic"] {
            let client = HermesCommandClient(provider: provider, model: "test-model", timeoutSeconds: 3, launcherURL: launcher)
            let empty = try await client.complete(systemPrompt: "sensitive-canary", userPrompt: "sensitive-canary", imageURLs: [])
            try check(empty == "0:", "zero images")
            let five = try await client.complete(systemPrompt: "sensitive-canary", userPrompt: "sensitive-canary", imageURLs: urls)
            try check(five == "5:" + urls.map(\.path).joined(separator: ","), "five ordered paths")
            let doctor = HermesCommandClient.doctor(provider: provider, model: "test-model", launcherURL: launcher, timeoutSeconds: 3)
            try check(doctor.passed && doctor.detail == "ready", "doctor success")
        }
        try check(!LogCapture.shared.joined.contains("sensitive-canary"), "prompt not logged")
        let client = HermesCommandClient(provider: "openai-codex", model: "test-model", timeoutSeconds: 3, launcherURL: launcher)
        try await mustFail("six images") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: urls + [urls[0]]) }
        let invalid = root.appendingPathComponent("invalid.png")
        try Data("not png".utf8).write(to: invalid)
        for url in [root, invalid, root.appendingPathComponent("missing.png"), URL(string: "https://example.invalid/a.png")!] {
            try await mustFail("invalid image") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: [url]) }
        }
        let forbidden = HermesCommandClient(provider: "openai", model: "test-model", launcherURL: launcher)
        try await mustFail("invalid provider") { try await forbidden.complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        for body in ["printf ''", "printf 'not json'", "printf '%s' '{\"ok\":true,\"text\":\"  \"}'", "printf '%s' '{\"ok\":false,\"error\":\"sensitive-canary\"}'", "printf '%s' '{\"ok\":true,\"text\":\"wrong\"}'; exit 7"] {
            let bad = HermesCommandClient(provider: "anthropic", model: "test-model", timeoutSeconds: 2, launcherURL: try script(body))
            try await mustFail("invalid/error/exit response") { try await bad.complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        }
        let flood = try script("exec /usr/bin/python3 -c 'import sys,json; sys.stderr.write(\"sensitive-canary\"*20000); r=json.load(sys.stdin); print(json.dumps({\"ok\":True,\"text\":\"x\"*200000}))'")
        let flooded = try await HermesCommandClient(provider: "anthropic", model: "test-model", timeoutSeconds: 3, launcherURL: flood).complete(systemPrompt: String(repeating: "s", count: 200000), userPrompt: "", imageURLs: [])
        try check(flooded.count == 200000, "concurrent pipe drains and stdin")
        let overflow = try script("exec /usr/bin/python3 -c 'import sys; sys.stdout.write(\"x\"*2000000)'")
        try await mustFail("bounded stdout") { try await HermesCommandClient(provider: "anthropic", model: "m", timeoutSeconds: 2, launcherURL: overflow).complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        let pidFile = root.appendingPathComponent("timed-out-pid")
        let sleepy = try script("echo $$ > '\(pidFile.path)'; trap '' TERM; exec /bin/sleep 15")
        let start = Date()
        try await mustFail("timeout") { try await HermesCommandClient(provider: "anthropic", model: "m", timeoutSeconds: 0.15, launcherURL: sleepy).complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        try check(Date().timeIntervalSince(start) < 2, "timeout bounded")
        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try check(kill(Int32(pidText)!, 0) == -1 && errno == ESRCH, "child killed and reaped")
        let doctor = HermesCommandClient.doctor(provider: "anthropic", model: "m", launcherURL: try script("printf '%s' '{\"ok\":false,\"error\":\"sensitive-canary\"}'"), timeoutSeconds: 1)
        try check(!doctor.passed && !doctor.detail.contains("sensitive-canary"), "safe doctor error")
        try check(!LogCapture.shared.joined.contains("sensitive-canary"), "stderr/errors not logged")
        let inherited = try script("/bin/sleep 0.7 &\n/bin/cat >/dev/null\nprintf '%s' '{\"ok\":true,\"text\":\"done\"}'")
        let inheritedStarted = Date()
        let inheritedText = try await HermesCommandClient(provider: "anthropic", model: "m", timeoutSeconds: 0.3, launcherURL: inherited).complete(systemPrompt: "", userPrompt: "", imageURLs: [])
        try check(inheritedText == "done" && Date().timeIntervalSince(inheritedStarted) < 0.5, "inherited pipes do not block reaping")
        let floodForever = try script("exec /usr/bin/python3 -c 'import os;\nwhile True: os.write(2,b\"sensitive-canary\"*4000)'")
        let floodStarted = Date()
        try await mustFail("endless stderr timeout") { try await HermesCommandClient(provider: "anthropic", model: "m", timeoutSeconds: 0.15, launcherURL: floodForever).complete(systemPrompt: String(repeating: "x", count: 200000), userPrompt: "", imageURLs: []) }
        try check(Date().timeIntervalSince(floodStarted) < 2, "stderr drain does not starve timeout")
        let blocked = try script("exec /bin/sleep 15")
        let blockedStarted = Date()
        try await mustFail("blocked stdin timeout") { try await HermesCommandClient(provider: "anthropic", model: "m", timeoutSeconds: 0.15, launcherURL: blocked).complete(systemPrompt: String(repeating: "x", count: 200000), userPrompt: "", imageURLs: []) }
        try check(Date().timeIntervalSince(blockedStarted) < 2, "stdin writes do not block timeout")
    }
    static func anthropic() async throws {
        let client = AnthropicMessagesClient(apiKey: "synthetic-anthropic-key", session: session(), requestTimeout: 2)
        let success = #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":" first "},{"type":"text","text":"second"}]}"#
        let urls = try images()
        for imageURLs in [[], urls] {
            HarnessURLProtocol.respond(success)
            let answer = try await client.complete(systemPrompt: "sensitive-canary", userPrompt: "sensitive-canary", imageURLs: imageURLs)
            try check(answer == "first \nsecond", "Anthropic text blocks")
            let json = try jsonRequest()
            let request = HarnessURLProtocol.captured!
            try check(request.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Messages endpoint")
            try check(request.httpMethod == "POST" && request.timeoutInterval == 2, "POST/timeout")
            try check(request.value(forHTTPHeaderField: "x-api-key") == "synthetic-anthropic-key", "API key header")
            try check(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "API version")
            try check(request.value(forHTTPHeaderField: "Authorization") == nil, "no Bearer header")
            try check(json["model"] as? String == "claude-haiku-5-5", "Anthropic default model")
            try check((json["max_tokens"] as? Int ?? 0) >= 4096, "sufficient budget")
            try check(json["tools"] == nil && json["tool_choice"] == nil, "no tools")
            try check(json["system"] as? String == "sensitive-canary", "system prompt")
            let messages = json["messages"] as! [[String: Any]]
            let content = messages[0]["content"] as! [[String: Any]]
            try check(content[0]["text"] as? String == "sensitive-canary", "user prompt")
            let images = content.filter { $0["type"] as? String == "image" }
            try check(images.count == imageURLs.count, "Anthropic image count")
            for (index, image) in images.enumerated() {
                let source = image["source"] as! [String: String]
                try check(source["type"] == "base64" && source["media_type"] == "image/png", "native PNG")
                let expected = try Data(contentsOf: imageURLs[index]).base64EncodedString()
                try check(source["data"] == expected, "Anthropic image order")
            }
        }
        let thinkingResponse = #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"thinking","thinking":"private reasoning","signature":"signed"},{"type":"redacted_thinking","data":"private"},{"type":"text","text":"final answer"}]}"#
        HarnessURLProtocol.respond(thinkingResponse)
        let thinkingAnswer = try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: [])
        try check(thinkingAnswer == "final answer", "Haiku default thinking blocks must not be delivered or reject a successful answer")
        let thinkingPayload = try jsonRequest()
        try check((thinkingPayload["output_config"] as? [String: String])?["effort"] == "low", "Haiku low effort")
        try check((thinkingPayload["thinking"] as? [String: String])?["type"] == "adaptive", "Haiku adaptive thinking")
        HarnessURLProtocol.respond(success)
        _ = try await AnthropicMessagesClient(apiKey: "key", model: "custom-haiku", session: session()).complete(systemPrompt: "", userPrompt: "", imageURLs: [])
        let configured = try jsonRequest()
        try check(configured["model"] as? String == "custom-haiku", "Anthropic configured model")
        for reason in ["max_tokens", "refusal", "tool_use", "pause_turn"] {
            HarnessURLProtocol.respond("{\"type\":\"message\",\"role\":\"assistant\",\"stop_reason\":\"\(reason)\",\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}")
            try await mustFail("Anthropic stop reason") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        }
        for body in ["", "{", "{}", #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[]}"#, #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"refusal","text":"no"}]}"#, #"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":" "}]}"#] {
            HarnessURLProtocol.respond(body)
            try await mustFail("Anthropic empty/malformed/refusal") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        }
        HarnessURLProtocol.respond(#"{"error":{"message":"sensitive-canary"}}"#, status: 401)
        try await mustFail("safe Anthropic HTTP error") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        try await mustFail("Anthropic six images") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: urls + [urls[0]]) }
        try await mustFail("Anthropic missing key") { try await AnthropicMessagesClient(apiKey: " ", session: session()).complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        for code in [URLError.Code.timedOut, .cannotConnectToHost] {
            HarnessURLProtocol.fail(code)
            try await mustFail("Anthropic safe network error") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: []) }
        }
        for url in [root, root.appendingPathComponent("invalid.png"), root.appendingPathComponent("missing.png")] {
            try await mustFail("Anthropic invalid images") { try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: [url]) }
        }
        try check(!LogCapture.shared.joined.contains("sensitive-canary"), "Anthropic diagnostics prompt safe")
        try check(!LogCapture.shared.joined.contains("synthetic-anthropic-key"), "Anthropic diagnostics key safe")
        for url in urls {
            let base64 = try Data(contentsOf: url).base64EncodedString()
            try check(!LogCapture.shared.joined.contains(base64), "Anthropic image data not logged")
        }
    }
    static func openAI() async throws {
        try check(OpenAIResponsesClient.model == "gpt-6-luna", "new default")
        let client = OpenAIResponsesClient(apiKey: "synthetic-test-key", model: "configured-model", session: session(), maxRetries: 0)
        HarnessURLProtocol.respond(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"answer"}]}]}"#)
        let answer = try await client.complete(systemPrompt: "secret-system", userPrompt: "secret-user")
        try check(answer == "answer", "OpenAI text")
        let payload = try jsonRequest()
        try check(payload["model"] as? String == "configured-model", "configured payload model")
        try check(client.displayName == "OpenAI configured-model", "configured display name")
        try check(LogCapture.shared.joined.contains("model=configured-model"), "configured diagnostics model")
        try check(!LogCapture.shared.joined.contains("secret-system"), "safe diagnostics")
    }
}
