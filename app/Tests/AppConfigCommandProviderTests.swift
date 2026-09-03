import Foundation
import XCTest
@testable import FluidPushToTalk

final class AppConfigCommandProviderTests: XCTestCase {
    func testDefaultCommandProviderIsOpenAI() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))

        XCTAssertEqual(config.commandProvider, .openAI)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any]
        )
        XCTAssertEqual(encoded["command_provider"] as? String, "openai")
    }

    func testCommandProviderDecodesCerebras() throws {
        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"command_provider":"cerebras"}"#.utf8)
        )

        XCTAssertEqual(config.commandProvider, .cerebras)
    }

    func testCommandProviderDecodesGemini() throws {
        let config = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"command_provider":"gemini"}"#.utf8)
        )

        XCTAssertEqual(config.commandProvider, .gemini)
    }
}
