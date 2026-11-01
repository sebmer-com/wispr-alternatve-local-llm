import Foundation
import XCTest
@testable import FluidPushToTalk

/// XCTest mirrors for full Xcode environments; the Python harness runs these transports
/// independently on Command Line Tools-only Macs using Swift 6 and actual subprocesses.
final class SubscriptionClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testHermesCompletesThroughStdinOnlyLauncher() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appendingPathComponent("bridge.sh")
        try Data("/bin/cat >/dev/null\nprintf '%s' '{\"ok\":true,\"text\":\"answer\"}'\n".utf8).write(to: launcher)
        let client = HermesCommandClient(provider: "openai-codex", model: "test-model", launcherURL: launcher)
        let result = try await client.complete(systemPrompt: "synthetic system", userPrompt: "synthetic user", imageURLs: [])
        XCTAssertEqual(result, "answer")
    }

    func testHermesRejectsUnsupportedProviderWithoutLaunching() async {
        let client = HermesCommandClient(provider: "openai", model: "test-model", launcherURL: URL(fileURLWithPath: "/does-not-exist"))
        do {
            _ = try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: [])
            XCTFail("Expected configuration rejection")
        } catch {
            XCTAssertEqual(error as? HermesCommandError, .invalidConfiguration)
        }
    }

    func testHermesDoctorNeverReturnsRawBridgeErrors() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = directory.appendingPathComponent("bridge.sh")
        try Data("/bin/cat >/dev/null\nprintf '%s' '{\"ok\":false,\"error\":\"synthetic-secret-canary\"}'\nexit 1\n".utf8).write(to: launcher)
        let result = HermesCommandClient.doctor(provider: "anthropic", model: "test-model", launcherURL: launcher)
        XCTAssertFalse(result.passed)
        XCTAssertFalse(result.detail.contains("synthetic-secret-canary"))
    }

    func testAnthropicReturnsTextAndRejectsTruncation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let client = AnthropicMessagesClient(apiKey: "synthetic-key", session: URLSession(configuration: config), logger: { _ in })
        URLProtocolStub.enqueue(status: 200, body: Data(#"{"type":"message","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"answer"}]}"#.utf8))
        let result = try await client.complete(systemPrompt: "", userPrompt: "question", imageURLs: [])
        XCTAssertEqual(result, "answer")
        XCTAssertEqual(URLProtocolStub.requests.first?.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        URLProtocolStub.enqueue(status: 200, body: Data(#"{"type":"message","role":"assistant","stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#.utf8))
        do {
            _ = try await client.complete(systemPrompt: "", userPrompt: "question", imageURLs: [])
            XCTFail("Never deliver partial answers")
        } catch {
            XCTAssertEqual(error as? AnthropicMessagesError, .truncated)
        }
    }

    func testAnthropicHTTPErrorDoesNotEchoProviderBody() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        let client = AnthropicMessagesClient(apiKey: "synthetic-key", session: URLSession(configuration: config), logger: { _ in })
        URLProtocolStub.enqueue(status: 401, body: Data(#"{"error":{"message":"synthetic-secret-canary"}}"#.utf8))
        do {
            _ = try await client.complete(systemPrompt: "", userPrompt: "", imageURLs: [])
            XCTFail("Expected HTTP rejection")
        } catch {
            XCTAssertEqual(error as? AnthropicMessagesError, .http(statusCode: 401))
            XCTAssertFalse(error.localizedDescription.contains("synthetic-secret-canary"))
        }
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/cache/scratch/subscription-xctest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
