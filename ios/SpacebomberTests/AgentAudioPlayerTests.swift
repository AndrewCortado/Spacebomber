import XCTest
@testable import Spacebomber

final class AgentAudioPlayerTests: XCTestCase {
    func testConverts16000And22050To24kHzWithoutDropping() {
        var resamplers: [Int: PCMResampler] = [:]
        let sixteen = AgentAudioPlayer.playbackSamples(
            from: PCMFrame(samples: ramp(1600), sampleRate: 16_000),
            resamplers: &resamplers
        )
        XCTAssertEqual(Double(sixteen.count), 2400, accuracy: 24)

        let twentyTwo = AgentAudioPlayer.playbackSamples(
            from: PCMFrame(samples: ramp(2205), sampleRate: 22_050),
            resamplers: &resamplers
        )
        let expected = 2205.0 * 24_000 / 22_050
        XCTAssertEqual(Double(twentyTwo.count), expected, accuracy: expected * 0.01)
        XCTAssertFalse(sixteen.isEmpty)
        XCTAssertFalse(twentyTwo.isEmpty)
    }
}

private func ramp(_ count: Int) -> Data {
    var data = Data(count: count * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for index in 0 ..< count {
            samples[index] = Int16(index % 1000).littleEndian
        }
    }
    return data
}
