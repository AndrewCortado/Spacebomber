import XCTest
@testable import Spacebomber

final class OpenAIRealtimeAgentTests: XCTestCase {
    func testSessionUpdateJSON() throws {
        let object = try jsonObject(OpenAIRealtimeAgent.sessionUpdate())
        XCTAssertEqual(object["type"] as? String, "session.update")
        let session = try XCTUnwrap(object["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "realtime")
        XCTAssertEqual(session["model"] as? String, "gpt-realtime-2.1")
        XCTAssertEqual(session["output_modalities"] as? [String], ["audio"])
        let audio = try XCTUnwrap(session["audio"] as? [String: Any])
        let input = try XCTUnwrap(audio["input"] as? [String: Any])
        let inputFormat = try XCTUnwrap(input["format"] as? [String: Any])
        XCTAssertEqual(inputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(number(inputFormat["rate"]), 24000)
        let turn = try XCTUnwrap(input["turn_detection"] as? [String: Any])
        XCTAssertEqual(turn["type"] as? String, "server_vad")
        let output = try XCTUnwrap(audio["output"] as? [String: Any])
        let outputFormat = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(outputFormat["type"] as? String, "audio/pcm")
        XCTAssertEqual(number(outputFormat["rate"]), 24000)
    }

    func testAppendEventRoundTripsPCM() throws {
        let pcm = Data([0x00, 0x01, 0xFF, 0x7F])
        let object = try jsonObject(OpenAIRealtimeAgent.appendEvent(pcm: pcm))
        XCTAssertEqual(object["type"] as? String, "input_audio_buffer.append")
        let encoded = try XCTUnwrap(object["audio"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), pcm)
    }

    func testEventFixtures() throws {
        XCTAssertEqual(try event(#"{"type":"session.updated"}"#), .ready)
        XCTAssertEqual(try event(#"{"type":"input_audio_buffer.speech_started"}"#), .userSpeechStarted)
        XCTAssertEqual(try event(#"{"type":"input_audio_buffer.speech_stopped"}"#), .userSpeechEnded)
        XCTAssertEqual(try event(#"{"type":"response.done"}"#), .responseDone)
        XCTAssertEqual(try event(#"{"type":"error","error":{"message":"bad model"}}"#), .status("bad model"))
        XCTAssertNil(try event(#"{"type":"rate_limits.updated"}"#))

        let pcm = Data([0x10, 0x20, 0x30, 0x40])
        let encoded = pcm.base64EncodedString()
        let delta = try event(#"{"type":"response.output_audio.delta","delta":"\#(encoded)"}"#)
        XCTAssertEqual(delta, .audio(PCMFrame(samples: pcm, sampleRate: 24_000)))
    }

    private func event(_ json: String) throws -> VoiceAgentEvent? {
        OpenAIRealtimeAgent.event(from: try XCTUnwrap(json.data(using: .utf8)))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
