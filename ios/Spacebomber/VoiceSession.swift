import Combine
import Foundation
import UIKit

@MainActor
final class VoiceSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case listening
        case userSpeaking
        case thinking
        case agentSpeaking
        case failed(String)

        var title: String {
            switch self {
            case .idle:
                "Idle"
            case .connecting:
                "Connecting"
            case .listening:
                "Listening"
            case .userSpeaking:
                "You're speaking"
            case .thinking:
                "Thinking"
            case .agentSpeaking:
                "Agent speaking"
            case .failed:
                "Failed"
            }
        }
    }

    static let halfDuplex = true
    static let halfDuplexTail: TimeInterval = 0.3

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var micLevel: Float = 0

    var isRunning: Bool {
        switch phase {
        case .idle, .failed:
            false
        default:
            true
        }
    }

    private let glasses: GlassesController
    private let makeAgent: () -> VoiceAgent?
    private let player: AgentPlayback
    private let now: () -> Date
    private var agent: VoiceAgent?
    private var running = false
    private var playbackActive = false
    private var gate = HalfDuplexGate()

    init(
        glasses: GlassesController,
        makeAgent: @escaping () -> VoiceAgent?,
        player: AgentPlayback? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.glasses = glasses
        self.makeAgent = makeAgent
        self.player = player ?? AgentAudioPlayer()
        self.now = now
        glasses.onMicPCM = { [weak self] frame in
            self?.ingest(frame)
        }
        bindPlayer()
    }

    func start() {
        guard !running else { return }
        guard let agent = makeAgent() else {
            phase = .failed(Secrets.missingKeyMessage)
            return
        }
        running = true
        self.agent = agent
        agent.onEvent = { [weak self] event in
            self?.handle(event)
        }
        phase = .connecting
        gate.clear()
        playbackActive = false
        bindPlayer()
        do {
            try player.start()
        } catch {
            running = false
            self.agent = nil
            phase = .failed(error.localizedDescription)
            return
        }
        agent.start()
        glasses.setMicStreaming(true)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        guard running else { return }
        running = false
        let current = agent
        agent = nil
        current?.onEvent = nil
        current?.stop()
        endPlayback()
        phase = .idle
    }

    private func bindPlayer() {
        player.onActiveChanged = { [weak self] active in
            self?.playbackChanged(active)
        }
    }

    private func ingest(_ frame: PCMFrame) {
        micLevel = Self.level(of: frame)
        guard running, let agent else { return }
        guard gate.allowsMic(at: now(), halfDuplex: Self.halfDuplex) else { return }
        agent.send(frame)
    }

    private func handle(_ event: VoiceAgentEvent) {
        guard running else { return }
        switch event {
        case .ready:
            if phase == .connecting {
                phase = .listening
            }
        case .userSpeechStarted:
            player.flush()
            gate.clear()
            phase = .userSpeaking
        case .userSpeechEnded:
            phase = .thinking
        case let .audio(frame):
            phase = .agentSpeaking
            player.enqueue(frame)
        case .responseDone:
            if !playbackActive {
                phase = .listening
            }
        case let .closed(error):
            running = false
            self.agent = nil
            endPlayback()
            if let error {
                phase = .failed(error)
            } else {
                phase = .idle
            }
        }
    }

    private func playbackChanged(_ active: Bool) {
        playbackActive = active
        glasses.setAgentAudioPlaying(active)
        if active {
            gate.playbackBegan()
            phase = .agentSpeaking
        } else {
            gate.playbackEnded(at: now(), tail: Self.halfDuplexTail)
            if phase == .agentSpeaking {
                phase = .listening
            }
        }
    }

    private func endPlayback() {
        player.onActiveChanged = nil
        player.stop()
        glasses.setMicStreaming(false)
        glasses.setAgentAudioPlaying(false)
        gate.clear()
        playbackActive = false
        micLevel = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private static func level(of frame: PCMFrame) -> Float {
        let samples = PCM.floats(fromInt16: frame.samples)
        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }
        return min(1, peak * 4)
    }
}
