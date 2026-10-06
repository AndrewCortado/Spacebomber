import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

enum PCM {
    static func floats(fromInt16 data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return [] }
        var floats = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0 ..< count {
                let sample = raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                floats[index] = Float(Int16(littleEndian: sample)) / 32768
            }
        }
        return floats
    }

    static func int16Data(from floats: [Float]) -> Data {
        var data = Data(count: floats.count * MemoryLayout<Int16>.size)
        data.withUnsafeMutableBytes { raw in
            for index in 0 ..< floats.count {
                let clamped = min(1, max(-1, floats[index]))
                let sample = Int16(clamped * 32767).littleEndian
                raw.storeBytes(of: sample, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return data
    }
}

#if canImport(AVFoundation)
final class PCMResampler {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init(from: Int, to: Int) {
        let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(from),
            channels: 1,
            interleaved: false
        )!
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(to),
            channels: 1,
            interleaved: false
        )!
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        converter.primeMethod = .none
        self.converter = converter
    }

    func convert(_ data: Data) -> Data {
        let input = PCM.floats(fromInt16: data)
        guard !input.isEmpty else { return Data() }
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(input.count)
        ) else { return Data() }
        inputBuffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress, let channel = inputBuffer.floatChannelData?[0] else { return }
            channel.update(from: address, count: input.count)
        }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.count) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return Data()
        }

        var provided = false
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, status in
            if provided {
                status.pointee = .noDataNow
                return nil
            }
            provided = true
            status.pointee = .haveData
            return inputBuffer
        }
        let frames = Int(outputBuffer.frameLength)
        guard frames > 0, let channel = outputBuffer.floatChannelData?[0] else { return Data() }
        var output = [Float](repeating: 0, count: frames)
        output.withUnsafeMutableBufferPointer { destination in
            guard let address = destination.baseAddress else { return }
            address.update(from: channel, count: frames)
        }
        return PCM.int16Data(from: output)
    }
}
#endif
