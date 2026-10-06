import AVFoundation
import Foundation

@MainActor
protocol AgentPlayback: AnyObject {
    var onActiveChanged: (@MainActor (Bool) -> Void)? { get set }
    func start() throws
    func enqueue(_ frame: PCMFrame)
    func flush()
    func stop()
}

@MainActor
final class AgentAudioPlayer: AgentPlayback {
    nonisolated static let outputRate = 24_000

    var onActiveChanged: (@MainActor (Bool) -> Void)?

    private let engine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let format: AVAudioFormat
    private var resamplers: [Int: PCMResampler] = [:]
    private var prepared = false
    private var pendingBuffers = 0
    private var playbackGeneration = 0
    private var engineObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.outputRate),
            channels: 1,
            interleaved: false
        )!
    }

    nonisolated static func playbackSamples(from frame: PCMFrame, resamplers: inout [Int: PCMResampler]) -> [Float] {
        let pcm: Data
        if frame.sampleRate == outputRate {
            pcm = frame.samples
        } else {
            let resampler = resamplers[frame.sampleRate] ?? PCMResampler(from: frame.sampleRate, to: outputRate)
            resamplers[frame.sampleRate] = resampler
            pcm = resampler.convert(frame.samples)
        }
        return PCM.floats(fromInt16: pcm)
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
        if !prepared {
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            prepared = true
        }
        if !engine.isRunning {
            try engine.start()
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        observeRouteChanges()
    }

    func enqueue(_ frame: PCMFrame) {
        guard engine.isRunning else { return }
        let samples = Self.playbackSamples(from: frame, resamplers: &resamplers)
        guard !samples.isEmpty else { return }
        schedule(samples)
    }

    func flush() {
        let wasActive = pendingBuffers > 0
        playbackGeneration += 1
        pendingBuffers = 0
        playerNode.stop()
        if engine.isRunning {
            playerNode.play()
        }
        if wasActive {
            onActiveChanged?(false)
        }
    }

    func stop() {
        removeObservers()
        playbackGeneration += 1
        pendingBuffers = 0
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    deinit {
        let center = NotificationCenter.default
        if let engineObserver {
            center.removeObserver(engineObserver)
        }
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
        }
    }

    private func observeRouteChanges() {
        if engineObserver == nil {
            engineObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.recoverPlayback()
                }
            }
        }
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] notification in
                Task { @MainActor in
                    self?.handleInterruption(notification)
                }
            }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
        guard let raw, AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
        recoverPlayback()
    }

    private func recoverPlayback() {
        let wasActive = pendingBuffers > 0
        playbackGeneration += 1
        pendingBuffers = 0
        if wasActive {
            onActiveChanged?(false)
        }
        guard prepared else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.play()
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let engineObserver {
            center.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        if let interruptionObserver {
            center.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
    }

    private func schedule(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let address = source.baseAddress else { return }
            channel.update(from: address, count: samples.count)
        }
        let generation = playbackGeneration
        let first = pendingBuffers == 0
        pendingBuffers += 1
        if first {
            onActiveChanged?(true)
        }
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                self?.didPlayBuffer(generation)
            }
        }
    }

    private func didPlayBuffer(_ generation: Int) {
        guard generation == playbackGeneration, pendingBuffers > 0 else { return }
        pendingBuffers -= 1
        if pendingBuffers == 0 {
            onActiveChanged?(false)
        }
    }
}

enum AudioRoute {
    @MainActor
    static func currentIsBluetooth() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            output.portType == .bluetoothA2DP
                || output.portType == .bluetoothHFP
                || output.portType == .bluetoothLE
        }
    }
}
