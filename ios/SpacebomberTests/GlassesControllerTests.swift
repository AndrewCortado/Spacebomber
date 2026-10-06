import MentraBluetoothSDK
import XCTest
@testable import Spacebomber

@MainActor
final class GlassesControllerTests: XCTestCase {
    func testConnectionPhaseMapsAllSdkStates() {
        XCTAssertEqual(ConnectionPhase.from(.disconnected), .disconnected)
        XCTAssertEqual(ConnectionPhase.from(.scanning), .searching)
        XCTAssertEqual(ConnectionPhase.from(.connecting), .connecting)
        XCTAssertEqual(ConnectionPhase.from(.bonding), .connecting)
        XCTAssertEqual(ConnectionPhase.from(.connected), .connected)
    }

    func testReconnectPolicyRetriesOnlyWhileDisconnectedWithASavedDevice() {
        let policy = ReconnectPolicy()
        XCTAssertTrue(policy.shouldRetry(phase: .disconnected, hasDefaultDevice: true, userDisconnected: false))
        XCTAssertFalse(policy.shouldRetry(phase: .disconnected, hasDefaultDevice: true, userDisconnected: true))
        XCTAssertFalse(policy.shouldRetry(phase: .disconnected, hasDefaultDevice: false, userDisconnected: false))
        XCTAssertFalse(policy.shouldRetry(phase: .searching, hasDefaultDevice: true, userDisconnected: false))
        XCTAssertFalse(policy.shouldRetry(phase: .connecting, hasDefaultDevice: true, userDisconnected: false))
        XCTAssertFalse(policy.shouldRetry(phase: .connected, hasDefaultDevice: true, userDisconnected: false))
    }
}
