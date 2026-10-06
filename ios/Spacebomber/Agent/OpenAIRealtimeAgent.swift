import Foundation

@MainActor
final class OpenAIRealtimeAgent: VoiceAgent {
    nonisolated static let endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    nonisolated static let model = "gpt-realtime-2.1"
    nonisolated static let pcmRate = 24_000

    var onEvent: (@MainActor (VoiceAgentEvent) -> Void)?

    private let apiKey: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var pending = Data()
    private var didClose = false
    private var didSendSessionUpdate = false
    private var resamplers: [Int: PCMResampler] = [:]

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    nonisolated static func sessionURL() -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return endpoint
        }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        return components.url ?? endpoint
    }

    nonisolated static func sessionUpdate() -> Data {
        let payload: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": model,
                "output_modalities": ["audio"],
                "instructions": "Short spoken answers; the user hears you through glasses.",
                "reasoning": ["effort": "low"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": pcmRate],
                        "noise_reduction": ["type": "near_field"],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.6,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                        ],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": pcmRate],
                        "voice": "marin",
                    ],
                ],
            ],
        ]
        return encode(payload)
    }

    nonisolated static func appendEvent(pcm: Data) -> Data {
        encode([
            "type": "input_audio_buffer.append",
            "audio": pcm.base64EncodedString(),
        ])
    }

    nonisolated static func event(from json: Data) -> VoiceAgentEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        switch type {
        case "session.updated":
            return .ready
        case "input_audio_buffer.speech_started":
            return .userSpeechStarted
        case "input_audio_buffer.speech_stopped":
            return .userSpeechEnded
        case "response.output_audio.delta":
            guard
                let encoded = object["delta"] as? String,
                let samples = Data(base64Encoded: encoded)
            else { return nil }
            return .audio(PCMFrame(samples: samples, sampleRate: pcmRate))
        case "response.done":
            return .responseDone
        case "error":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? "Realtime error"
            return .status(message)
        default:
            return nil
        }
    }

    func start() {
        didClose = false
        didSendSessionUpdate = false
        pending.removeAll()
        var request = URLRequest(url: Self.sessionURL())
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        sendSessionUpdate()
        receiveNext()
    }

    func send(_ frame: PCMFrame) {
        guard !didClose else { return }
        let pcm = resampled(frame)
        guard !pcm.isEmpty else { return }
        pending.append(pcm)
        flushPending(partial: false)
    }

    func stop() {
        flushPending(partial: true)
        finish(error: nil)
    }

    private func resampled(_ frame: PCMFrame) -> Data {
        if frame.sampleRate == Self.pcmRate {
            return frame.samples
        }
        let resampler = resamplers[frame.sampleRate] ?? PCMResampler(from: frame.sampleRate, to: Self.pcmRate)
        resamplers[frame.sampleRate] = resampler
        return resampler.convert(frame.samples)
    }

    private func sendSessionUpdate() {
        guard !didSendSessionUpdate else { return }
        didSendSessionUpdate = true
        transmit(Self.sessionUpdate())
    }

    private func flushPending(partial: Bool) {
        let chunk = Self.appendBytes
        while pending.count >= chunk {
            let audio = Data(pending.prefix(chunk))
            pending.removeFirst(chunk)
            transmit(Self.appendEvent(pcm: audio))
        }
        if partial, !pending.isEmpty {
            transmit(Self.appendEvent(pcm: pending))
            pending.removeAll()
        }
    }

    private func transmit(_ data: Data) {
        guard let socket, !didClose, let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { [weak self] error in
            guard let message = error?.localizedDescription else { return }
            Task { @MainActor in
                self?.finish(error: message)
            }
        }
    }

    private func receiveNext() {
        guard !didClose, let socket else { return }
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.didClose else { return }
                switch result {
                case let .failure(error):
                    self.finish(error: error.localizedDescription)
                case let .success(message):
                    self.consume(message)
                    self.receiveNext()
                }
            }
        }
    }

    private func consume(_ message: URLSessionWebSocketTask.Message) {
        let text: String?
        switch message {
        case let .string(value):
            text = value
        case let .data(data):
            text = String(data: data, encoding: .utf8)
        @unknown default:
            text = nil
        }
        guard let text, let data = text.data(using: .utf8), let event = Self.event(from: data) else { return }
        onEvent?(event)
    }

    private func finish(error: String?) {
        guard !didClose else { return }
        didClose = true
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onEvent?(.closed(error: error))
    }

    private static let appendBytes = 4800

    nonisolated private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
