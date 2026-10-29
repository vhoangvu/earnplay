import Foundation

/// Movement-trade motion verification (T3.1) — deterministic, CoreMotion-abstracted.
///
/// Production motion comes from CoreMotion in the child app (see
/// `CoreMotionSampleProvider` in the EarnPlay target). This file defines the
/// abstraction (`MotionSampleProvider`), the deterministic rep counter
/// (`VerifiedRepCounter`), and the injected fixtures (`MotionFixtures`) that
/// stand in for CoreMotion in tests and simulator previews — the simulator
/// cannot do real CoreMotion, so no test or preview ever touches the sensor.
///
/// Counting rule: the counter watches the deviation of acceleration
/// magnitude from 1g. A rep is one full peak-plus-valley swing whose
/// arm-to-complete duration fits exercise cadence. Stillness never arms the
/// detector; fast erratic shaking completes swings too quickly to verify.
/// Every counted rep therefore matched the offered activity's cadence.
///
/// Gyroscope samples are carried for future anti-cheat work; today they act
/// only as a guard (samples with extreme rotation are ignored, never
/// counted).

// MARK: - Sample

/// One motion sample. In production this is mapped 1:1 from a CoreMotion
/// `CMDeviceMotion` update; in tests and previews it comes from fixtures.
public struct MotionSample: Equatable, Sendable {
    /// Seconds on the stream's monotonic clock (sensor timestamp or
    /// fixture offset). Only differences between timestamps are read.
    public var timestamp: TimeInterval
    /// User-acceleration-plus-gravity components in g (≈1g at rest).
    public var ax: Double
    public var ay: Double
    public var az: Double
    /// Rotation-rate components in rad/s.
    public var gx: Double
    public var gy: Double
    public var gz: Double

    public init(timestamp: TimeInterval, ax: Double, ay: Double, az: Double,
                gx: Double = 0, gy: Double = 0, gz: Double = 0) {
        self.timestamp = timestamp
        self.ax = ax
        self.ay = ay
        self.az = az
        self.gx = gx
        self.gy = gy
        self.gz = gz
    }

    public var accelerationMagnitude: Double {
        (ax * ax + ay * ay + az * az).squareRoot()
    }

    public var rotationMagnitude: Double {
        (gx * gx + gy * gy + gz * gz).squareRoot()
    }

    /// The signal the counter watches: how far acceleration magnitude
    /// deviates from 1g. Near zero at rest, oscillating during exercise.
    public var magnitudeDeviation: Double { accelerationMagnitude - 1.0 }
}

// MARK: - Provider abstraction

/// Motion-sample source. The app target provides the real CoreMotion
/// implementation and a fixture-replay implementation for the simulator
/// preview; tests bypass providers and feed fixtures straight into
/// `VerifiedRepCounter.ingest(_:)`.
public protocol MotionSampleProvider: AnyObject {
    /// False when the sensor (or fixture source) cannot produce samples.
    var isAvailable: Bool { get }
    /// Begins streaming samples to `handler` (≈50 Hz in production).
    /// The handler may be invoked on any queue; callers marshal to the
    /// queue they need.
    func startUpdates(handler: @escaping @Sendable (MotionSample) -> Void)
    /// Stops the stream started by `startUpdates(handler:)`.
    func stopUpdates()
}

// MARK: - Verified rep counter

/// Detector thresholds. Tuned so a ~1–2 Hz exercise swing verifies while
/// stillness (no threshold crossing) and fast shaking (swings complete too
/// quickly) do not. One rep is one full oscillation: the detector arms on
/// the rising (positive) crossing only, so each cycle counts exactly once.
public struct RepCounterConfig: Equatable, Sendable {
    /// Magnitude-deviation level that arms one side of a swing (±this).
    public var armThreshold: Double
    /// Fastest arm-to-complete swing that can verify (shaking is faster).
    public var minRepDuration: TimeInterval
    /// Slowest arm-to-complete swing kept armed (stale arms disarm).
    public var maxRepDuration: TimeInterval
    /// Minimum gap between two counted reps.
    public var minSeparation: TimeInterval
    /// Samples rotating faster than this are ignored, never counted.
    public var maxRotationRate: Double
    /// Trailing window for the cadence veto, in seconds.
    public var cadenceWindowSeconds: TimeInterval
    /// Maximum zero crossings per second inside the cadence window for a
    /// candidate rep to verify. Exercise at ≤2 Hz crosses ~4/s (plus
    /// impact ringing); shaking at ≥4 Hz crosses ≥8/s. The veto sits
    /// between them at 6/s: slow hand sweeps inside a shaking stream
    /// still see the surrounding vibration rate and are rejected.
    public var maxZeroCrossingsPerSecond: Double
    /// Deadband around zero for crossing detection, in g.
    public var crossingDeadband: Double

    public init(armThreshold: Double = 0.35,
                minRepDuration: TimeInterval = 0.25,
                maxRepDuration: TimeInterval = 2.5,
                minSeparation: TimeInterval = 0.4,
                maxRotationRate: Double = 12.0,
                cadenceWindowSeconds: TimeInterval = 1.0,
                maxZeroCrossingsPerSecond: Double = 6.0,
                crossingDeadband: Double = 0.05) {
        self.armThreshold = armThreshold
        self.minRepDuration = minRepDuration
        self.maxRepDuration = maxRepDuration
        self.minSeparation = minSeparation
        self.maxRotationRate = maxRotationRate
        self.cadenceWindowSeconds = cadenceWindowSeconds
        self.maxZeroCrossingsPerSecond = maxZeroCrossingsPerSecond
        self.crossingDeadband = crossingDeadband
    }

    public static let `default` = RepCounterConfig()
}

/// Counts verified repetitions from a motion stream.
///
/// Phase machine: idle → armed (signal crossed +threshold) → rep completed
/// when the signal crosses −threshold. Arming on the rising crossing only
/// makes one rep exactly one full oscillation. A completed swing counts only
/// when its duration fits exercise cadence
/// (`minRepDuration...maxRepDuration`), it is separated from the previous
/// counted rep (`minSeparation`), and the trailing cadence window does not
/// look like fast vibration (the zero-crossing-rate veto, which rejects
/// shaking even when a slow hand sweep sneaks a valid-duration swing
/// through). Anything else is rejected and tallied in
/// `rejectedNoiseEvents` for the trade record's evidence summary.
public struct VerifiedRepCounter: Equatable, Sendable {
    public let targetReps: Int
    public let config: RepCounterConfig
    public private(set) var verifiedCount = 0
    /// Completed swings rejected as too fast / too close together.
    public private(set) var rejectedNoiseEvents = 0
    public private(set) var ingestedSamples = 0

    private enum Phase: Equatable, Sendable {
        case idle
        /// Rising crossing seen; waiting for the falling opposite crossing.
        case armed(at: TimeInterval)
    }

    private var phase: Phase = .idle
    private var lastCountedAt: TimeInterval?
    /// Timestamps of recent deviation zero crossings (cadence veto).
    private var crossingTimes: [TimeInterval] = []
    /// Last deviation sign outside the deadband (+1 / −1 / nil).
    private var lastSign: Int?
    /// First sample timestamp; the veto rate is measured over observed time
    /// so the veto also holds while the window is still filling.
    private var streamStartAt: TimeInterval?

    public init(targetReps: Int, config: RepCounterConfig = .default) {
        self.targetReps = max(1, targetReps)
        self.config = config
    }

    public var isComplete: Bool { verifiedCount >= targetReps }

    /// Ingests one sample; returns the verified count after ingesting.
    @discardableResult
    public mutating func ingest(_ sample: MotionSample) -> Int {
        ingestedSamples += 1
        if streamStartAt == nil { streamStartAt = sample.timestamp }
        guard sample.rotationMagnitude <= config.maxRotationRate else {
            // A rejected interval must not bridge two endpoints into one
            // rep: disarm, so a spin between an arm and a later valid
            // crossing cannot verify across the rejected gap.
            phase = .idle
            return verifiedCount
        }
        let signal = sample.magnitudeDeviation
        let now = sample.timestamp
        trackCrossing(signal: signal, at: now)
        switch phase {
        case .idle:
            armIfCrossing(signal: signal, at: now)
        case .armed(let armedAt):
            if now - armedAt > config.maxRepDuration {
                // Stale arm: disarm, then let this sample arm afresh.
                phase = .idle
                armIfCrossing(signal: signal, at: now)
                return verifiedCount
            }
            guard signal <= -config.armThreshold else { return verifiedCount }
            phase = .idle
            guard now - armedAt >= config.minRepDuration else {
                rejectedNoiseEvents += 1
                return verifiedCount
            }
            if let last = lastCountedAt, now - last < config.minSeparation {
                rejectedNoiseEvents += 1
                return verifiedCount
            }
            guard !cadenceVetoed(at: now) else {
                rejectedNoiseEvents += 1
                return verifiedCount
            }
            verifiedCount += 1
            lastCountedAt = now
        }
        return verifiedCount
    }

    /// Ingests a stream; returns the verified count after ingesting.
    @discardableResult
    public mutating func ingest(_ samples: [MotionSample]) -> Int {
        for sample in samples { ingest(sample) }
        return verifiedCount
    }

    public mutating func reset() {
        verifiedCount = 0
        rejectedNoiseEvents = 0
        ingestedSamples = 0
        phase = .idle
        lastCountedAt = nil
        crossingTimes = []
        lastSign = nil
        streamStartAt = nil
    }

    private mutating func armIfCrossing(signal: Double, at time: TimeInterval) {
        // Rising crossing only: one full oscillation per rep.
        if signal >= config.armThreshold {
            phase = .armed(at: time)
        }
    }

    /// Records deviation zero crossings (with deadband hysteresis so noise
    /// near zero cannot chatter), pruning outside the cadence window.
    private mutating func trackCrossing(signal: Double, at time: TimeInterval) {
        if signal > config.crossingDeadband {
            if lastSign == -1 { crossingTimes.append(time) }
            lastSign = 1
        } else if signal < -config.crossingDeadband {
            if lastSign == 1 { crossingTimes.append(time) }
            lastSign = -1
        }
        let cutoff = time - config.cadenceWindowSeconds
        while let first = crossingTimes.first, first < cutoff {
            crossingTimes.removeFirst()
        }
    }

    /// True when the trailing window shows fast vibration rather than
    /// exercise cadence. The rate is measured over observed time (not the
    /// full window) so early vibration cannot sneak through cold.
    private func cadenceVetoed(at time: TimeInterval) -> Bool {
        let cutoff = time - config.cadenceWindowSeconds
        let recent = crossingTimes.filter { $0 >= cutoff }.count
        let observed = max(time - (streamStartAt ?? time), 0.1)
        let span = min(config.cadenceWindowSeconds, observed)
        return Double(recent) / span > config.maxZeroCrossingsPerSecond
    }
}

// MARK: - Injected fixtures (test + simulator-preview support)

/// Deterministic motion-sample fixtures. These stand in for CoreMotion
/// wherever the sensor is unavailable (host tests, simulator, previews).
/// Noise comes from `EffortSeededRNG`, so every fixture replays exactly.
public enum MotionFixtures {
    /// Fixture sample rate, matching the production provider (≈50 Hz).
    public static let sampleRateHz = 50.0

    /// Genuine jumping-jack cadence: rhythmic ~1.1 Hz pocket motion.
    /// Counts to `repCount` on `VerifiedRepCounter`.
    public static func genuineJumpingJacks(repCount: Int = 12, seed: UInt64 = 7) -> [MotionSample] {
        rhythmicMotion(repCount: repCount, cadenceHz: 1.1, amplitudeG: 0.8, seed: seed)
    }

    /// Genuine running-in-place cadence: rhythmic ~1.6 Hz pocket motion.
    /// Counts to `repCount` on `VerifiedRepCounter`.
    public static func genuineRunningInPlace(repCount: Int = 12, seed: UInt64 = 11) -> [MotionSample] {
        rhythmicMotion(repCount: repCount, cadenceHz: 1.6, amplitudeG: 0.7, seed: seed)
    }

    /// Rhythmic pocket motion at exercise cadence: exactly `repCount` full
    /// swings followed by a neutral tail, so the verified count equals
    /// `repCount` exactly.
    public static func rhythmicMotion(repCount: Int, cadenceHz: Double,
                                      amplitudeG: Double = 0.8, seed: UInt64 = 7,
                                      noiseG: Double = 0.03) -> [MotionSample] {
        precondition(repCount > 0 && cadenceHz > 0)
        var rng = EffortSeededRNG(seed: seed)
        let dt = 1.0 / sampleRateHz
        let cycles = Double(repCount)
        let exerciseSeconds = cycles / cadenceHz
        let tailSeconds = 0.5
        let total = Int((exerciseSeconds + tailSeconds) * sampleRateHz)
        var samples: [MotionSample] = []
        samples.reserveCapacity(total)
        for index in 0..<total {
            let time = Double(index) * dt
            let swing: Double
            if time < exerciseSeconds {
                swing = amplitudeG * sin(2.0 * .pi * cadenceHz * time)
            } else {
                swing = 0
            }
            samples.append(MotionSample(
                timestamp: time,
                ax: 0.1 * sin(2.0 * .pi * cadenceHz * time + 1.3) + noise(&rng, noiseG),
                ay: 0.08 * sin(4.0 * .pi * cadenceHz * time + 0.5) + noise(&rng, noiseG),
                az: 1.0 + swing + noise(&rng, noiseG),
                gx: 0.6 * sin(2.0 * .pi * cadenceHz * time + 0.7),
                gy: 0.4 * sin(2.0 * .pi * cadenceHz * time + 2.1),
                gz: 0.3 * sin(2.0 * .pi * cadenceHz * time + 4.0)))
        }
        return samples
    }

    /// Phone lying still: ~1g with tiny noise. Never arms the detector.
    public static func phoneOnTable(durationSeconds: Double = 10, seed: UInt64 = 3) -> [MotionSample] {
        var rng = EffortSeededRNG(seed: seed)
        let dt = 1.0 / sampleRateHz
        let total = Int(durationSeconds * sampleRateHz)
        return (0..<total).map { index in
            MotionSample(
                timestamp: Double(index) * dt,
                ax: noise(&rng, 0.015), ay: noise(&rng, 0.015), az: 1.0 + noise(&rng, 0.015),
                gx: noise(&rng, 0.02), gy: noise(&rng, 0.02), gz: noise(&rng, 0.02))
        }
    }

    /// Phone shaken in hand: fast (≈5–12 Hz) erratic multi-axis swings with
    /// large rotation. Crosses the arm thresholds constantly, but swings
    /// complete far too quickly to verify, and the vibration-rate veto
    /// rejects anything a slow hand sweep sneaks through. Component
    /// frequencies keep ≥3 Hz apart so no slow beat mimics exercise.
    public static func shakingInHand(durationSeconds: Double = 10, seed: UInt64 = 5) -> [MotionSample] {
        var rng = EffortSeededRNG(seed: seed)
        let dt = 1.0 / sampleRateHz
        let total = Int(durationSeconds * sampleRateHz)
        // Seed-picked phases keep replays deterministic but not identical.
        let p1 = Double(rng.next() % 628) / 100.0
        let p2 = Double(rng.next() % 628) / 100.0
        let p3 = Double(rng.next() % 628) / 100.0
        return (0..<total).map { index in
            let time = Double(index) * dt
            return MotionSample(
                timestamp: time,
                ax: 0.9 * sin(2.0 * .pi * 5.2 * time + p1)
                    + 0.4 * sin(2.0 * .pi * 9.1 * time + p2) + noise(&rng, 0.05),
                ay: 0.7 * sin(2.0 * .pi * 6.3 * time + p3)
                    + 0.4 * sin(2.0 * .pi * 10.4 * time + p1) + noise(&rng, 0.05),
                az: 1.0 + 0.8 * sin(2.0 * .pi * 7.4 * time + p2)
                    + 0.5 * sin(2.0 * .pi * 11.7 * time + p3) + noise(&rng, 0.05),
                gx: 7.0 * sin(2.0 * .pi * 5.7 * time + p1),
                gy: 6.0 * sin(2.0 * .pi * 6.8 * time + p2),
                gz: 5.0 * sin(2.0 * .pi * 4.9 * time + p3))
        }
    }

    private static func noise(_ rng: inout EffortSeededRNG, _ amplitude: Double) -> Double {
        (Double(rng.next() % 1000) / 1000.0 * 2.0 - 1.0) * amplitude
    }
}
