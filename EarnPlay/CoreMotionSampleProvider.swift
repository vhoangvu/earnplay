import CoreMotion
import EarnPlayCore
import Foundation

/// Production motion provider (T3.1): streams `CMDeviceMotion` at 50 Hz mapped
/// 1:1 onto `MotionSample` (user acceleration + gravity ≈ 1g at rest, exactly
/// the signal `VerifiedRepCounter` watches). Constructed only on the accept
/// path of an AI-initiated offer — never from a menu or child action.
final class CoreMotionSampleProvider: MotionSampleProvider {
    private let manager: CMMotionManager
    private let queue: OperationQueue

    init(manager: CMMotionManager = CMMotionManager()) {
        self.manager = manager
        self.queue = OperationQueue()
        self.queue.maxConcurrentOperationCount = 1
        self.queue.name = "earnplay.motion"
    }

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func startUpdates(handler: @escaping @Sendable (MotionSample) -> Void) {
        startUpdates(handler: handler, onFailure: { _ in })
    }

    func startUpdates(handler: @escaping @Sendable (MotionSample) -> Void,
                      onFailure: @escaping @Sendable (Error) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / MotionFixtures.sampleRateHz
        manager.startDeviceMotionUpdates(to: queue) { motion, error in
            if let error {
                onFailure(error)
                return
            }
            guard let motion else {
                onFailure(NSError(
                    domain: "EarnPlayMotion", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Motion sample unavailable"]))
                return
            }
            handler(MotionSample(
                timestamp: motion.timestamp,
                ax: motion.userAcceleration.x + motion.gravity.x,
                ay: motion.userAcceleration.y + motion.gravity.y,
                az: motion.userAcceleration.z + motion.gravity.z,
                gx: motion.rotationRate.x,
                gy: motion.rotationRate.y,
                gz: motion.rotationRate.z))
        }
    }

    func stopUpdates() {
        manager.stopDeviceMotionUpdates()
    }
}

/// Simulator/preview provider (T3.1): replays a fixture stream on a timer at
/// the production sample rate. Used by the DEBUG preview (the simulator has
/// no motion sensor) and never in production counting.
final class FixtureReplayProvider: MotionSampleProvider {
    var isAvailable: Bool { true }

    private let samples: [MotionSample]
    private var timer: Timer?
    private var index = 0

    /// - Parameter samples: the stream to replay (default: genuine
    ///   jumping jacks that verify to the default 10-rep target).
    init(samples: [MotionSample] = MotionFixtures.genuineJumpingJacks(repCount: 12)) {
        self.samples = samples
    }

    func startUpdates(handler: @escaping @Sendable (MotionSample) -> Void) {
        stopUpdates()
        index = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / MotionFixtures.sampleRateHz,
                                     repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            guard self.index < self.samples.count else { timer.invalidate(); return }
            let sample = self.samples[self.index]
            self.index += 1
            handler(sample)
        }
    }

    func stopUpdates() {
        timer?.invalidate()
        timer = nil
    }
}
