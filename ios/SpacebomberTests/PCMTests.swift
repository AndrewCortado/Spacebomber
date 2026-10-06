import XCTest
@testable import Spacebomber

final class PCMTests: XCTestCase {
    func testInt16ScalesToFloat() {
        let data = int16Data([0, 32767, -32768])
        let floats = PCM.floats(fromInt16: data)
        XCTAssertEqual(floats.count, 3)
        XCTAssertEqual(floats[0], 0)
        XCTAssertEqual(floats[1], Float(32767) / 32768, accuracy: 0.00001)
        XCTAssertEqual(floats[2], -1)
    }

    func testResamples1600SamplesAt16kHzToAbout2400At24kHz() {
        let data = ramp(1600)
        let output = PCMResampler(from: 16_000, to: 24_000).convert(data)
        let samples = output.count / 2
        XCTAssertEqual(Double(samples), 2400, accuracy: 24)
    }

    func testChunkedResampleMatchesOneChunk() {
        let data = ramp(1600)
        let one = PCMResampler(from: 16_000, to: 24_000).convert(data)
        let chunked = PCMResampler(from: 16_000, to: 24_000)
        let mid = data.count / 2
        let first = chunked.convert(Data(data.prefix(mid)))
        let second = chunked.convert(Data(data.suffix(from: mid)))
        XCTAssertEqual(first.count + second.count, one.count)
    }
}

private func int16Data(_ values: [Int16]) -> Data {
    var data = Data(count: values.count * MemoryLayout<Int16>.size)
    data.withUnsafeMutableBytes { raw in
        let samples = raw.bindMemory(to: Int16.self)
        for index in values.indices {
            samples[index] = values[index].littleEndian
        }
    }
    return data
}

private func ramp(_ count: Int) -> Data {
    int16Data((0 ..< count).map { Int16($0 % 1000) })
}
