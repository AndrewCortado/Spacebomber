import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: GlassesController
    @ObservedObject var session: VoiceSession

    private var hasAPIKey: Bool { Secrets.openAIKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(controller.phase.title)
                .font(.largeTitle.bold())
            if controller.isReconnecting {
                Text("Reconnecting…")
                    .font(.title3)
            }
            if let statusMessage = controller.statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.secondary)
            }
            if controller.needsAudioRouteHint {
                Text(GlassesController.audioRouteHint)
            }
            Text(session.phase.title)
                .font(.title2)
            if !hasAPIKey {
                Text(Secrets.missingKeyMessage)
            } else if case let .failed(message) = session.phase {
                Text(message)
            }
            HStack {
                Text("Mic")
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.secondary.opacity(0.2))
                        Rectangle().frame(width: proxy.size.width * CGFloat(min(max(session.micLevel, 0), 1)))
                    }
                }
                .frame(height: 12)
            }
            ForEach(controller.devices) { device in
                Button(device.name) {
                    controller.connect(device)
                }
                .buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 12) {
                Button("Scan", action: controller.scan)
                Button("Reconnect", action: controller.reconnect)
                Button("Disconnect", action: controller.disconnect)
                Button("Start", action: session.start)
                    .disabled(!hasAPIKey || session.isRunning)
                Button("Stop", action: session.stop)
                    .disabled(!session.isRunning)
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
