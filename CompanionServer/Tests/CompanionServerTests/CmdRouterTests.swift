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

    func testSpeechRequestEncodesPCMResponseFormat() throws {
        let request = SpeechRequest(model: "tts-1", input: "hello", voice: "alloy", responseFormat: "pcm")
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]

        XCTAssertEqual(json?["model"], "tts-1")
        XCTAssertEqual(json?["input"], "hello")
        XCTAssertEqual(json?["voice"], "alloy")
        XCTAssertEqual(json?["response_format"], "pcm")
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
        XCTAssertFalse(CompanionPrompt.system.isEmpty)
        XCTAssertEqual(CompanionPrompt.userMessage(for: "tes suara"), "tes suara")
    }

    func testTranscriptPipelineProducesTextAndAudioOutput() async throws {
        let outbound = TestOutboundWriter()
        let speakerWriter = TestOutboundWriter()
        let openAI = StubOpenAIService(
            transcript: "ignored",
            chatResult: ChatToolResult(reply: "Hello from test", command: nil),
            speechData: Data([0, 1, 2, 3, 4, 5, 6, 7])
        )
        let logger = Logger(label: "VoiceSessionTests")
        let speakers = SpeakerRegistry(logger: logger)
        await speakers.register(id: UUID(), outbound: speakerWriter)

        let session = VoiceSession(outbound: outbound, openAI: openAI, speakers: speakers, logger: logger)
        try await session.start()
        await session.handleTranscriptInput("halo dunia")

        let messages = try await waitForMessages(on: outbound, count: 5)
        XCTAssertTrue(messages.contains(.textContaining("\"type\":\"session.ready\"")))
        XCTAssertTrue(messages.contains(.textContaining("\"type\":\"transcript.final\"")))
        XCTAssertTrue(messages.contains(.textContaining("\"type\":\"tts.start\"")))
        XCTAssertTrue(messages.contains(.binary(Data([0, 1, 2, 3, 4, 5, 6, 7]))))
        XCTAssertTrue(messages.contains(.textContaining("\"type\":\"tts.end\"")))

        let speakerMessages = try await waitForMessages(on: speakerWriter, count: 2)
        XCTAssertTrue(speakerMessages.contains(.textContaining("\"type\":\"tts.start\"")))
        XCTAssertTrue(speakerMessages.contains(.binary(Data([0, 1, 2, 3, 4, 5, 6, 7]))))
    }

    func testSpeechFailureFallsBackToAudioFrames() {
        let pcm = Data(repeating: 7, count: uplinkFrameBytes + 10)
        let payload = TestClient.makeSubmissionPayload(
            pcm: pcm,
            transcriptResult: .failure(TestClientError.speechRecognitionFailed("Retry"))
        )

        switch payload {
        case .transcript:
            XCTFail("Expected audio fallback payload")
        case .audioFrames(let frames):
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames[0], pcm.prefix(uplinkFrameBytes))
            XCTAssertEqual(frames[1], pcm.suffix(10))
        }
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

private func waitForMessages(on writer: TestOutboundWriter, count: Int, timeoutMs: Int = 1000) async throws -> [RecordedMessage] {
    let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
    while Date() < deadline {
        let messages = await writer.messages
        if messages.count >= count {
            return messages
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await writer.messages
}

private actor TestOutboundWriter: SessionOutboundWriter {
    private(set) var messages: [RecordedMessage] = []

    func writeText(_ text: String) async throws {
        messages.append(.text(text))
    }

    func writeBinary(_ data: Data) async throws {
        messages.append(.binary(data))
    }
}

private struct StubOpenAIService: OpenAIService {
    let transcript: String
    let chatResult: ChatToolResult
    let speechData: Data

    func transcribe(wav: Data) async throws -> String {
        transcript
    }

    func chat(transcript: String) async throws -> ChatToolResult {
        chatResult
    }

    func speech(text: String) async throws -> Data {
        speechData
    }
}

private enum RecordedMessage: Equatable {
    case text(String)
    case binary(Data)

    static func textContaining(_ fragment: String) -> Self {
        .text(fragment)
    }

    static func == (lhs: RecordedMessage, rhs: RecordedMessage) -> Bool {
        switch (lhs, rhs) {
        case let (.text(left), .text(right)):
            return left.contains(right)
        case let (.binary(left), .binary(right)):
            return left == right
        default:
            return false
        }
    }
}
