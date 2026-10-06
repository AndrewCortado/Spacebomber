import AVFoundation
import Foundation
import MentraBluetoothSDK
import SwiftUI

extension ConnectionPhase {
    static func from(_ state: GlassesConnectionState) -> ConnectionPhase {
        switch state {
        case .scanning:
            .searching
        case .connecting, .bonding:
            .connecting
        case .connected:
            .connected
        case .disconnected:
            .disconnected
        @unknown default:
            .disconnected
        }
    }
}

@MainActor
final class GlassesController: ObservableObject, MentraBluetoothSDKDelegate {
    static let audioRouteHint = "select Mentra Live in Settings → Bluetooth"

    @Published private(set) var phase: ConnectionPhase = .disconnected
    @Published private(set) var devices: [Device] = []
    @Published private(set) var needsAudioRouteHint = false
    @Published private(set) var isReconnecting = false
    @Published private(set) var statusMessage: String?

    var onMicPCM: (@MainActor (PCMFrame) -> Void)?

    private let sdk: MentraBluetoothSDK
    private let defaults: UserDefaults
    private let routeIsBluetooth: @MainActor () -> Bool
    private let reconnectPolicy = ReconnectPolicy()
    private var savedDevice: Device?
    private var userDisconnected = false
    private var glassesReady = false
    // Mentra Live discovery does not publish GlassesConnectionState.scanning.
    private var scanning = false
    private var scanSession: ScanSession?
    private var retryTimer: Timer?
    private var foreground = true
    private var started = false
    private var routeObserver: NSObjectProtocol?
    private var micTask: Task<Void, Never>?

    init(
        sdk: MentraBluetoothSDK? = nil,
        defaults: UserDefaults = .standard,
        routeIsBluetooth: (@MainActor () -> Bool)? = nil
    ) {
        let sdk = sdk ?? MentraBluetoothSDK(configuration: .init(analytics: .disabled))
        self.sdk = sdk
        self.defaults = defaults
        self.routeIsBluetooth = routeIsBluetooth ?? { AudioRoute.currentIsBluetooth() }
        savedDevice = Self.storedDevice(in: defaults)
        sdk.delegate = self
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleAudioRouteChange()
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if let savedDevice {
            sdk.setDefaultDevice(savedDevice)
            beginConnectDefault(reconnecting: true)
        } else {
            scan()
        }
    }

    func scan() {
        let previous = scanSession
        scanSession = nil
        scanning = false
        previous?.stop()

        scanning = true
        devices = []
        statusMessage = nil
        applyPhase(.searching)
        isReconnecting = false
        do {
            scanSession = try sdk.scan(model: .mentraLive, timeout: 15, onResults: { [weak self] found in
                MainActor.assumeIsolated {
                    self?.devices = found
                }
            }, onComplete: { [weak self] found in
                MainActor.assumeIsolated {
                    self?.finishScan(found)
                }
            })
        } catch {
            scanning = false
            scanSession = nil
            statusMessage = Self.message(for: error)
            applyPhase(.disconnected)
        }
    }

    func connect(_ device: Device) {
        userDisconnected = false
        scanning = false
        savedDevice = device
        persist(device)
        isReconnecting = false
        statusMessage = nil
        let session = scanSession
        scanSession = nil
        applyPhase(.connecting)
        session?.stop()
        do {
            try sdk.connect(to: device)
        } catch {
            statusMessage = Self.message(for: error)
            applyPhase(.disconnected)
        }
    }

    func reconnect() {
        if savedDevice == nil {
            savedDevice = Self.storedDevice(in: defaults)
        }
        guard let savedDevice else {
            statusMessage = "No saved glasses. Scan and choose Mentra Live."
            return
        }
        sdk.setDefaultDevice(savedDevice)
        beginConnectDefault(reconnecting: true)
    }

    func disconnect() {
        userDisconnected = true
        scanning = false
        glassesReady = false
        isReconnecting = false
        needsAudioRouteHint = false
        let session = scanSession
        scanSession = nil
        statusMessage = nil
        session?.stop()
        sdk.disconnect()
        applyPhase(.disconnected)
    }

    func setMicStreaming(_ on: Bool) {
        micTask?.cancel()
        micTask = Task { [weak self] in
            guard let self else { return }
            if on {
                try? await self.sdk.setVoiceActivityDetectionEnabled(false)
                try? await self.sdk.setLoudnessGateEnabled(true)
            }
            guard !Task.isCancelled else { return }
            self.sdk.setMicState(enabled: on, useGlassesMic: true)
        }
    }

    func setAgentAudioPlaying(_ playing: Bool) {
        sdk.setOwnAppAudioPlaying(playing)
    }

    func appBecameActive() {
        foreground = true
        guard started else { return }
        retryIfNeeded()
        updateRetryTimer()
    }

    func appLeftForeground() {
        foreground = false
        updateRetryTimer()
    }

    func handleAudioRouteChange() {
        updateAudioRouteHint()
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didUpdateGlasses glasses: GlassesRuntimeState) {
        glassesReady = glasses.ready
        let mapped = ConnectionPhase.from(glasses.connection)
        if scanning, mapped == .disconnected {
            applyPhase(.searching)
        } else {
            if mapped == .connecting || mapped == .connected {
                scanning = false
            }
            applyPhase(mapped)
        }
        if glasses.ready {
            statusMessage = nil
        }
        updateAudioRouteHint()
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didFail error: BluetoothSdkError) {
        statusMessage = error.message
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didReceive event: BluetoothEvent) {
        guard case let .micHealth(health) = event else { return }
        statusMessage = "mic_health reason=\(health.reason) sequenceGapEvents=\(health.sequenceGapEvents) decodeFailures=\(health.decodeFailures)"
    }

    func mentraBluetoothSDK(_: MentraBluetoothSDK, didReceiveMicPcm event: MicPcmEvent) {
        onMicPCM?(PCMFrame(samples: event.pcm, sampleRate: event.sampleRate))
    }

    private func beginConnectDefault(reconnecting: Bool) {
        guard savedDevice != nil else { return }
        userDisconnected = false
        scanning = false
        isReconnecting = reconnecting
        statusMessage = nil
        let session = scanSession
        scanSession = nil
        applyPhase(.connecting)
        session?.stop()
        do {
            try sdk.connectDefault()
        } catch {
            statusMessage = Self.message(for: error)
            applyPhase(.disconnected)
            if reconnecting {
                isReconnecting = true
            }
        }
    }

    private func finishScan(_ found: [Device]) {
        devices = found
        scanSession = nil
        scanning = false
        guard phase == .searching else { return }
        applyPhase(.disconnected)
    }

    private func retryIfNeeded() {
        guard foreground else { return }
        guard reconnectPolicy.shouldRetry(
            phase: phase,
            hasDefaultDevice: savedDevice != nil,
            userDisconnected: userDisconnected
        ) else { return }
        beginConnectDefault(reconnecting: true)
    }

    private func applyPhase(_ newPhase: ConnectionPhase) {
        if phase == .connected, newPhase != .connected, !userDisconnected {
            isReconnecting = true
        }
        if newPhase == .connected {
            isReconnecting = false
        }
        phase = newPhase
        updateRetryTimer()
    }

    private func updateRetryTimer() {
        let allow = foreground && reconnectPolicy.shouldRetry(
            phase: phase,
            hasDefaultDevice: savedDevice != nil,
            userDisconnected: userDisconnected
        )
        if allow {
            guard retryTimer == nil else { return }
            let timer = Timer(timeInterval: reconnectPolicy.interval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.retryIfNeeded()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryTimer = timer
        } else {
            retryTimer?.invalidate()
            retryTimer = nil
        }
    }

    private func updateAudioRouteHint() {
        needsAudioRouteHint = glassesReady && !routeIsBluetooth()
    }

    private func persist(_ device: Device) {
        defaults.set(device.model.deviceType, forKey: StorageKey.model)
        defaults.set(device.name, forKey: StorageKey.name)
        defaults.set(device.identifier ?? "", forKey: StorageKey.identifier)
    }

    private static func storedDevice(in defaults: UserDefaults) -> Device? {
        guard
            let model = defaults.string(forKey: StorageKey.model), !model.isEmpty,
            let name = defaults.string(forKey: StorageKey.name), !name.isEmpty
        else {
            return nil
        }
        let identifier = defaults.string(forKey: StorageKey.identifier).flatMap { $0.isEmpty ? nil : $0 }
        return Device(model: .fromDeviceType(model), name: name, identifier: identifier)
    }

    private static func message(for error: Error) -> String {
        if let sdkError = error as? BluetoothSdkError {
            return sdkError.message
        }
        return error.localizedDescription
    }
}

private enum StorageKey {
    static let model = "spacebomber.savedDevice.model"
    static let name = "spacebomber.savedDevice.name"
    static let identifier = "spacebomber.savedDevice.identifier"
}
