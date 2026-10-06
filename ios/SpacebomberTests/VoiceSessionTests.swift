import XCTest
@testable import Spacebomber

@MainActor
final class VoiceSessionTests: XCTestCase {
    func testHalfDuplexDropsMicWhileTheAgentSpeaksAndDuringTheTail() {
        let agent = FakeVoiceAgent()
        let player = SpyPlayer()
        let clock = ManualClock(Date(timeIntervalSinceReferenceDate: 10_000))
        let (session, glasses) = makeSession(agent: agent, player: player, now: { clock.date })
        session.start()
        XCTAssertEqual(session.phase, .listening)

        let mic = PCMFrame(samples: Data([1, 0, 2, 0]), sampleRate: 16_000)
        glasses.onMicPCM?(mic)
        XCTAssertEqual(agent.sent, [mic])

        agent.emit(.audio(PCMFrame(samples: Data([8, 0]), sampleRate: 16_000)))
        XCTAssertEqual(player.frames.count, 1)
        glasses.onMicPCM?(mic)
        XCTAssertEqual(agent.sent.count, 1)

        player.finishPlayback()
        glasses.onMicPCM?(mic)
        XCTAssertEqual(agent.sent.count, 1)

        clock.date = clock.date.addingTimeInterval(2)
        glasses.onMicPCM?(mic)
        XCTAssertEqual(agent.sent.count, 2)
    }

    func testEventsMapToPhases() {
        let agent = FakeVoiceAgent()
        let player = SpyPlayer()
        let (session, _) = makeSession(agent: agent, player: player)
        session.start()
        XCTAssertEqual(session.phase, .listening)

        agent.emit(.userSpeechStarted)
        XCTAssertEqual(session.phase, .userSpeaking)
        agent.emit(.userSpeechEnded)
        XCTAssertEqual(session.phase, .thinking)
        agent.emit(.audio(PCMFrame(samples: Data([1, 0]), sampleRate: 24_000)))
        XCTAssertEqual(session.phase, .agentSpeaking)
        agent.emit(.responseDone)
        XCTAssertEqual(session.phase, .agentSpeaking)
        player.finishPlayback()
        XCTAssertEqual(session.phase, .listening)

        agent.emit(.closed(error: "boom"))
        XCTAssertEqual(session.phase, .failed("boom"))
    }

    func testMissingKeyFails() {
        let (session, _) = makeSession(agent: nil, player: SpyPlayer())
        session.start()
        guard case let .failed(message) = session.phase else {
            return XCTFail("expected a failed session")
        }
        XCTAssertTrue(message.contains("OPENAI_API_KEY"))
        XCTAssertTrue(message.contains("Local.xcconfig"))
        XCTAssertFalse(session.isRunning)
    }

    func testSixteenKilohertzReplyReachesThePlayer() {
        let agent = FakeVoiceAgent()
        let player = SpyPlayer()
        let (session, _) = makeSession(agent: agent, player: player)
        session.start()
        let frame = PCMFrame(samples: Data([9, 8, 7, 6]), sampleRate: 16_000)
        agent.emit(.audio(frame))
        XCTAssertEqual(player.frames, [frame])
        XCTAssertEqual(session.phase, .agentSpeaking)
    }

    private func makeSession(
        agent: FakeVoiceAgent?,
        player: SpyPlayer,
        now: @escaping () -> Date = Date.init
    ) -> (VoiceSession, GlassesController) {
        let glasses = makeGlasses()
        let session = VoiceSession(
            glasses: glasses,
            makeAgent: {
                if let agent {
                    return agent as VoiceAgent
                }
                return nil
            },
            player: player,
            now: now
        )
        return (session, glasses)
    }

    private func makeGlasses() -> GlassesController {
        let name = "SpacebomberTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return GlassesController(defaults: defaults)
    }
}

@MainActor
private final class FakeVoiceAgent: VoiceAgent {
    var onEvent: (@MainActor (VoiceAgentEvent) -> Void)?
    private(set) var sent: [PCMFrame] = []

    func start() {
        onEvent?(.ready)
    }

    func send(_ frame: PCMFrame) {
        sent.append(frame)
    }

    func stop() {
        onEvent?(.closed(error: nil))
    }

    func emit(_ event: VoiceAgentEvent) {
        onEvent?(event)
    }
}

@MainActor
private final class SpyPlayer: AgentPlayback {
    var onActiveChanged: (@MainActor (Bool) -> Void)?
    private(set) var frames: [PCMFrame] = []
    private var active = false

    func start() throws {}

    func enqueue(_ frame: PCMFrame) {
        frames.append(frame)
        if !active {
            active = true
            onActiveChanged?(true)
        }
    }

    func flush() {
        guard active else { return }
        active = false
        onActiveChanged?(false)
    }

    func stop() {
        active = false
    }

    func finishPlayback() {
        guard active else { return }
        active = false
        onActiveChanged?(false)
    }
}

private final class ManualClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}
