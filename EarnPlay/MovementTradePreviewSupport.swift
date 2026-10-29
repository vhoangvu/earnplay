import EarnPlayCore
import Foundation

/// Accept-path motion provider selection (T3.1 fix round 1).
///
/// Real CoreMotion on a physical device; fixture replay only on the
/// simulator or in an explicit DEBUG test mode (launch argument
/// `--earnplay-fixture-motion` for on-device fixture runs). The
/// simulator demo keeps working because the simulator branch still
/// replays fixtures — but leaving a physical phone on a table can no
/// longer verify reps through replayed motion.
enum MotionProviderFactory {
    /// True when running on the simulator (no motion sensor).
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    /// Explicit test-only override for on-device fixture runs. Always
    /// false in production (non-DEBUG), where the provider is the sensor.
    static var fixtureOverrideEnabled: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("--earnplay-fixture-motion")
        #else
            return false
        #endif
    }

    /// Pure decision, unit-tested: replay only on simulator/test mode.
    static func useFixtureReplay(isSimulator: Bool, fixtureOverride: Bool) -> Bool {
        isSimulator || fixtureOverride
    }

    /// Selects the accept-path provider for the given environment.
    static func makeAcceptProvider(isSimulator: Bool, fixtureOverride: Bool,
                                   replayProvider: FixtureReplayProvider) -> MotionSampleProvider {
        if useFixtureReplay(isSimulator: isSimulator, fixtureOverride: fixtureOverride) {
            return replayProvider
        }
        return CoreMotionSampleProvider()
    }

    /// Production entry point: reads the real environment. The replay
    /// stream is built lazily, so a physical device never even constructs
    /// the fixture it does not use.
    static func makeAcceptProvider(
        replayProvider: @autoclosure () -> FixtureReplayProvider) -> MotionSampleProvider {
        if useFixtureReplay(isSimulator: isSimulator, fixtureOverride: fixtureOverrideEnabled) {
            return replayProvider()
        }
        return CoreMotionSampleProvider()
    }
}

/// Preview/learning session identity (T3.1 fix round 1).
///
/// Every preview session mints a fresh ID, shared by the cap lookup and
/// `presentOffer`, so a previous session's decline, abandonment, or grant
/// never blocks a new session's debug trigger (the old shared literal did,
/// permanently, until application data was deleted).
struct PreviewSession {
    var id: String = UUID().uuidString

    /// Starts a new session identity within a live preview.
    mutating func startNewSession() {
        id = UUID().uuidString
    }
}
