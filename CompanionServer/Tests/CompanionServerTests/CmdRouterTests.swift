import XCTest
@testable import CompanionServer
@testable import TestClient
import Logging

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

    func testTranscriptInputDecodesAsInboundMessage() throws {
        let json = #"{"type":"transcript.input","text":"halo dunia"}"#
        let data = Data(json.utf8)

        let envelope = try JSONDecoder().decode(InboundEnvelope.self, from: data)
        XCTAssertEqual(envelope.type, .transcriptInput)

        let message = try JSONDecoder().decode(TranscriptInput.self, from: data)
        XCTAssertEqual(message.text, "halo dunia")
    }

    func testCompanionPromptProvidesSystemAndUserMessages() {
        XCTAssertFalse(CompanionPrompt.system(responseLanguage: "English").isEmpty)
        XCTAssertEqual(CompanionPrompt.userMessage(for: "tes suara"), "tes suara")
    }

    func testCompanionPromptIncludesPreambleGuidance() {
        let prompt = CompanionPrompt.system(responseLanguage: "English").lowercased()
        XCTAssertTrue(prompt.contains("preamble"))
        XCTAssertTrue(prompt.contains("web_search"))
        XCTAssertTrue(prompt.contains("casual"))
        XCTAssertTrue(prompt.contains("serious"))
    }

    func testCompanionPromptLanguageInstruction() {
        let english = CompanionPrompt.system(responseLanguage: "English").lowercased()
        XCTAssertTrue(english.contains("always respond in english"))

        let auto = CompanionPrompt.system(responseLanguage: "auto").lowercased()
        XCTAssertTrue(auto.contains("same language as the user's transcript"))
    }

    func testTalkToSpeechMetricsComputesDurations() {
        let captureStartedAt = Date(timeIntervalSinceReferenceDate: 100)
        let captureFinishedAt = Date(timeIntervalSinceReferenceDate: 103.5)
        let firstDownlinkAt = Date(timeIntervalSinceReferenceDate: 105.25)

        let metrics = TestClient.makeTalkToSpeechMetrics(
            captureStartedAt: captureStartedAt,
            captureFinishedAt: captureFinishedAt,
            firstDownlinkAt: firstDownlinkAt
        )

        XCTAssertEqual(metrics.talkDurationMs, 3500)
        XCTAssertEqual(metrics.stopToSpeechMs, 1750)
        XCTAssertEqual(metrics.talkToSpeechMs, 5250)
    }
}
