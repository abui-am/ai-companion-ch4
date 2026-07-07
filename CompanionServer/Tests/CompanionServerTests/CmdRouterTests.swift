import XCTest
@testable import CompanionServer
@testable import TestClient
import CompanionDatabase
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
        XCTAssertTrue(prompt.contains("tasks"))
        XCTAssertTrue(prompt.contains("calendar"))
        XCTAssertTrue(prompt.contains("8pm"))
        XCTAssertTrue(prompt.contains("never"))
        XCTAssertTrue(prompt.contains("casual"))
        XCTAssertTrue(prompt.contains("serious"))
    }

    func testCompanionPromptLanguageInstruction() {
        let english = CompanionPrompt.system(responseLanguage: "English").lowercased()
        XCTAssertTrue(english.contains("always respond in english"))

        let auto = CompanionPrompt.system(responseLanguage: "auto").lowercased()
        XCTAssertTrue(auto.contains("same language as the user's transcript"))
    }

    func testCompanionPromptPersonalityInstruction() {
        let calm = CompanionPrompt.system(responseLanguage: "English", personality: .calm).lowercased()
        XCTAssertTrue(calm.contains("calm"))
        XCTAssertTrue(calm.contains("gentle"))

        let energetic = CompanionPrompt.system(responseLanguage: "English", personality: .energetic).lowercased()
        XCTAssertTrue(energetic.contains("energetic"))
        XCTAssertTrue(energetic.contains("uplifting"))

        let professional = CompanionPrompt.system(responseLanguage: "English", personality: .professional).lowercased()
        XCTAssertTrue(professional.contains("professional"))
        XCTAssertTrue(professional.contains("direct"))
    }

    func testCompanionPromptDefaultsToCalmPersonality() {
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let withDefault = CompanionPrompt.system(
            responseLanguage: "English",
            timeZone: jakarta,
            now: fixedNow
        )
        let withExplicitCalm = CompanionPrompt.system(
            responseLanguage: "English",
            personality: .calm,
            timeZone: jakarta,
            now: fixedNow
        )
        XCTAssertEqual(withDefault, withExplicitCalm)
    }

    func testCompanionPromptIncludesTimezoneContext() {
        let fixedNow = Date(timeIntervalSince1970: 1_780_000_000)
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        let prompt = CompanionPrompt.system(
            responseLanguage: "English",
            timeZone: jakarta,
            now: fixedNow
        )
        XCTAssertTrue(prompt.contains("Asia/Jakarta"))
        XCTAssertTrue(prompt.contains("Current local time:"))
    }

    func testConfigLanguagePromptLabels() {
        XCTAssertEqual(ConfigLanguage.english.promptLabel, "English")
        XCTAssertEqual(ConfigLanguage.spanish.promptLabel, "Spanish")
        XCTAssertEqual(ConfigLanguage.french.promptLabel, "French")
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
