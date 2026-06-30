import XCTest
@testable import CompanionServer

final class CmdRouterTests: XCTestCase {
    func testValidSetLEDPasses() throws {
        let cmd = DeviceCommand(action: "set_led", params: LEDParams(r: 10, g: 20, b: 30))
        XCTAssertNoThrow(try CmdRouter.validate(cmd))
    }

    func testUnknownActionRejected() {
        let cmd = DeviceCommand(action: "play_sound", params: LEDParams(r: 0, g: 0, b: 0))
        XCTAssertThrowsError(try CmdRouter.validate(cmd)) { error in
            XCTAssertEqual(error as? ValidationError, .unknownAction)
        }
    }

    func testOutOfRangeRejected() {
        let cmd = DeviceCommand(action: "set_led", params: LEDParams(r: 300, g: 0, b: 0))
        XCTAssertThrowsError(try CmdRouter.validate(cmd)) { error in
            XCTAssertEqual(error as? ValidationError, .outOfRange)
        }
    }

    func testSpeechRequestEncodesPCMResponseFormat() throws {
        let request = SpeechRequest(model: "tts-1", input: "hello", voice: "alloy", responseFormat: "pcm")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]

        XCTAssertEqual(json?["model"], "tts-1")
        XCTAssertEqual(json?["input"], "hello")
        XCTAssertEqual(json?["voice"], "alloy")
        XCTAssertEqual(json?["response_format"], "pcm")
    }
}
