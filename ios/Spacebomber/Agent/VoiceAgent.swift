import Foundation

struct PCMFrame: Equatable, Sendable {
    var samples: Data
    var sampleRate: Int
}

enum VoiceAgentEvent: Equatable, Sendable {
    case ready
    case userSpeechStarted
    case userSpeechEnded
    case audio(PCMFrame)
    case responseDone
    case closed(error: String?)
}

@MainActor
protocol VoiceAgent: AnyObject {
    var onEvent: (@MainActor (VoiceAgentEvent) -> Void)? { get set }
    func start()
    func send(_ frame: PCMFrame)
    func stop()
}

enum ConnectionPhase: Equatable {
    case searching
    case connecting
    case connected
    case disconnected

    var title: String {
        switch self {
        case .searching:
            "Searching"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnected:
            "Disconnected"
        }
    }
}

struct ReconnectPolicy: Equatable {
    var interval: TimeInterval = 30

    func shouldRetry(phase: ConnectionPhase, hasDefaultDevice: Bool, userDisconnected: Bool) -> Bool {
        phase == .disconnected && hasDefaultDevice && !userDisconnected
    }
}

struct HalfDuplexGate: Equatable {
    private(set) var blockedUntil: Date?

    mutating func playbackBegan() {
        blockedUntil = .distantFuture
    }

    mutating func playbackEnded(at now: Date, tail: TimeInterval) {
        blockedUntil = now.addingTimeInterval(tail)
    }

    mutating func clear() {
        blockedUntil = nil
    }

    func allowsMic(at now: Date, halfDuplex: Bool) -> Bool {
        guard halfDuplex, let blockedUntil else { return true }
        return now >= blockedUntil
    }
}
