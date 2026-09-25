import Foundation
import XCTest
@testable import FluidPushToTalk

final class FailedCommandTurnStoreTests: XCTestCase {
    func testRetainCopiesImagesAndWritesManifestThenClearRemovesBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let imageData = Data([0x89, 0x50, 0x4E, 0x47])
        let source = root.appendingPathComponent("source.png")
        try imageData.write(to: source)
        let store = FailedCommandTurnStore(rootURL: root.appendingPathComponent("last-failed-command"))

        try store.retain(
            provider: "Cerebras",
            model: "qwen-3.8-27b",
            information: "voice information",
            command: "voice command",
            errorDescription: "timeout",
            imageURLs: [source]
        )

        let manifestURL = store.rootURL.appendingPathComponent("turn.json")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("voice information"))
        XCTAssertTrue(manifest.contains("voice command"))
        XCTAssertTrue(manifest.contains("timeout"))
        let retainedImages = try FileManager.default
            .contentsOfDirectory(at: store.rootURL, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(retainedImages.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retainedImages.first)), imageData)
        XCTAssertEqual(try permissions(of: store.rootURL), 0o700)
        XCTAssertEqual(try permissions(of: manifestURL), 0o600)
        XCTAssertEqual(try permissions(of: XCTUnwrap(retainedImages.first)), 0o600)

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootURL.path))
    }

    func testNewFailureReplacesPreviousFailedTurn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FailedCommandTurnStore(rootURL: root.appendingPathComponent("last-failed-command"))

        try store.retain(
            provider: "OpenAI",
            model: "gpt-5.6-luna",
            information: "first",
            command: "first command",
            errorDescription: "first error",
            imageURLs: []
        )
        try store.retain(
            provider: "Cerebras",
            model: "qwen-3.8-27b",
            information: "second",
            command: "second command",
            errorDescription: "second error",
            imageURLs: []
        )

        let manifest = try String(
            contentsOf: store.rootURL.appendingPathComponent("turn.json"),
            encoding: .utf8
        )
        XCTAssertFalse(manifest.contains("first error"))
        XCTAssertTrue(manifest.contains("second error"))
    }

    func testPromotionFailureRestoresPreviousBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("last-failed-command")
        let store = FailedCommandTurnStore(rootURL: storeURL)
        try store.retain(
            provider: "OpenAI",
            model: "gpt-5.6-luna",
            information: "original information",
            command: "original command",
            errorDescription: "original error",
            imageURLs: []
        )
        let failingStore = FailedCommandTurnStore(rootURL: storeURL) {
            throw PromotionFailure.injected
        }

        XCTAssertThrowsError(try failingStore.retain(
            provider: "Cerebras",
            model: "qwen-3.8-27b",
            information: "replacement information",
            command: "replacement command",
            errorDescription: "replacement error",
            imageURLs: []
        ))

        let manifest = try String(
            contentsOf: storeURL.appendingPathComponent("turn.json"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("original error"))
        XCTAssertFalse(manifest.contains("replacement error"))
    }

    func testStagingFailurePreservesPreviousBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("last-failed-command")
        let store = FailedCommandTurnStore(rootURL: storeURL)
        try store.retain(
            provider: "OpenAI",
            model: "gpt-5.6-luna",
            information: "original information",
            command: "original command",
            errorDescription: "original error",
            imageURLs: []
        )
        let missingImage = root.appendingPathComponent("missing.png")

        XCTAssertThrowsError(try store.retain(
            provider: "Cerebras",
            model: "qwen-3.8-27b",
            information: "replacement information",
            command: "replacement command",
            errorDescription: "replacement error",
            imageURLs: [missingImage]
        ))

        let manifest = try String(
            contentsOf: storeURL.appendingPathComponent("turn.json"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("original error"))
        XCTAssertFalse(manifest.contains("replacement error"))
        let parentItems = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(parentItems.contains { $0.hasPrefix(".last-failed-command.tmp-") })
    }

    func testInitializationRecoversBundleMovedToBackupDuringCrashWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("last-failed-command")
        let store = FailedCommandTurnStore(rootURL: storeURL)
        try store.retain(
            provider: "Cerebras",
            model: "qwen-3.8-27b",
            information: "recoverable information",
            command: "recoverable command",
            errorDescription: "recoverable error",
            imageURLs: []
        )
        let backupURL = root.appendingPathComponent(".last-failed-command.backup-crash")
        try FileManager.default.moveItem(at: storeURL, to: backupURL)

        _ = FailedCommandTurnStore(rootURL: storeURL)

        let manifest = try String(
            contentsOf: storeURL.appendingPathComponent("turn.json"),
            encoding: .utf8
        )
        XCTAssertTrue(manifest.contains("recoverable error"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try permissions(of: storeURL), 0o700)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

private enum PromotionFailure: Error {
    case injected
}
