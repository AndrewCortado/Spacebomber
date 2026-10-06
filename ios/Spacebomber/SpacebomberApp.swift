import Foundation
import SwiftUI

enum Secrets {
    static let missingKeyMessage = "Add OPENAI_API_KEY to ios/Config/Local.xcconfig"

    static var openAIKey: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("$(") || trimmed == "YOUR_OPENAI_API_KEY" {
            return nil
        }
        return trimmed
    }
}

@main
struct SpacebomberApp: App {
    @StateObject private var controller: GlassesController
    @StateObject private var session: VoiceSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let controller = GlassesController()
        _controller = StateObject(wrappedValue: controller)
        _session = StateObject(wrappedValue: VoiceSession(
            glasses: controller,
            makeAgent: { Secrets.openAIKey.map { OpenAIRealtimeAgent(apiKey: $0) } }
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, session: session)
                .onAppear { controller.start() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        controller.appBecameActive()
                    } else {
                        controller.appLeftForeground()
                    }
                }
        }
    }
}
