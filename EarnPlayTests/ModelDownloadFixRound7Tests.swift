import XCTest

/// Test-only guard that shelters a pre-existing file at a location a
/// test must temporarily occupy (the real default model destination).
///
/// Contract (pinned by `ModelDownloadFixRound7Tests`):
/// 1. The backup lives OUTSIDE every temp root the suite cleans, so
///    temp-root cleanup can never delete the only copy of a
///    pre-existing file.
/// 2. Restoration is established BEFORE the sentinel write, so a
///    sentinel-write failure still restores the original
///    byte-identical.
final class ShelteredFileGuard {
    private(set) var tempRoots: [URL] = []

    func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelteredFileGuard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    func removeTempRoots() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
    }

    /// Shelters any pre-existing file at `real`, runs `write` to place
    /// the sentinel, runs `body` (suite flows + cleanup), then removes
    /// the sentinel and restores the original. `body` receives the
    /// backup URL, or nil when nothing pre-existed.
    func run(real: URL,
             sentinel: Data,
             write: (URL, Data) throws -> Void,
             body: (URL?) throws -> Void) throws {
        let parentDir = real.deletingLastPathComponent()
        let parentExisted = FileManager.default.fileExists(atPath: parentDir.path)
        let hadOriginal = FileManager.default.fileExists(atPath: real.path)
        // The shelter root is deliberately UNTRACKED (never appended
        // to tempRoots): temp-root cleanup removes only tracked roots,
        // so it can never delete the only copy of a pre-existing file.
        let shelterRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelteredFileGuard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: shelterRoot, withIntermediateDirectories: true)
        var shelter: URL?
        var sentinelWritten = false
        // Registered BEFORE the sentinel write: a write failure still
        // removes our partial bytes and restores the original.
        // `real` is removed only when it can hold nothing but our
        // bytes — the shelter-move failure below throws before `real`
        // could be touched, leaving a pre-existing file in place.
        defer {
            if shelter != nil || sentinelWritten || !hadOriginal {
                try? FileManager.default.removeItem(at: real)
            }
            if !parentExisted {
                try? FileManager.default.removeItem(at: parentDir)
            }
            if let shelter {
                do {
                    try FileManager.default.moveItem(at: shelter, to: real)
                } catch {
                    XCTFail("FAILED to restore sheltered file from \(shelter.path) to \(real.path): \(error)")
                }
            }
            try? FileManager.default.removeItem(at: shelterRoot)
        }
        if hadOriginal {
            let backup = shelterRoot.appendingPathComponent("sheltered-original")
            do {
                try FileManager.default.moveItem(at: real, to: backup)
            } catch {
                throw XCTSkip("cannot shelter the pre-existing file at \(real.path); refusing to risk it: \(error)")
            }
            print("round7: sheltered pre-existing \(real.path) at \(backup.path)")
            shelter = backup
        }
        try write(real, sentinel)
        sentinelWritten = true
        try body(shelter)
    }
}

/// Fix round 7 regression tests (issue #53): the real-destination
/// survival test shelters a pre-existing model before planting its
/// sentinel. The shelter backup must survive temp-root cleanup, and a
/// sentinel-write failure must still restore the original
/// byte-identical — otherwise the test itself risks permanent loss of
/// an existing model.
///
/// These tests run the shelter sequence against a fake "real" file
/// under temp (never the actual default destination), so they are
/// hermetic and risk nothing.
final class ModelDownloadFixRound7Tests: XCTestCase {
    private struct WriteFailed: Error {}

    private func makeFakeReal(payload: Data) throws -> (home: URL, real: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadFixRound7Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let real = home.appendingPathComponent("model.gguf")
        try payload.write(to: real)
        return (home, real)
    }

    /// Temp-root cleanup (what `tearDown` does) must never delete the
    /// shelter backup, and the original must be restored byte-identical.
    func testTempCleanupNeverDeletesShelterBackup() throws {
        let guard_ = ShelteredFileGuard()
        let payload = Data("round7-pre-existing-model".utf8)
        let (home, real) = try makeFakeReal(payload: payload)
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = Data("round7-sentinel".utf8)

        try guard_.run(real: real, sentinel: sentinel,
            write: { url, data in try data.write(to: url) },
            body: { backup in
                guard_.removeTempRoots()
                let backupURL = try XCTUnwrap(backup, "a pre-existing file must have been sheltered")
                XCTAssertEqual(try? Data(contentsOf: backupURL), payload,
                    "temp cleanup must never delete the shelter backup")
            })
        XCTAssertEqual(try? Data(contentsOf: real), payload,
            "the pre-existing file must be restored byte-identical")
    }

    /// A sentinel-write failure must still restore the pre-existing
    /// file byte-identical — restoration cannot wait until after a
    /// write that may throw.
    func testSentinelWriteFailureStillRestoresOriginal() throws {
        let guard_ = ShelteredFileGuard()
        let payload = Data("round7-pre-existing-model".utf8)
        let (home, real) = try makeFakeReal(payload: payload)
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = Data("round7-sentinel".utf8)

        XCTAssertThrowsError(try guard_.run(real: real, sentinel: sentinel,
            write: { _, _ in throw WriteFailed() },
            body: { _ in XCTFail("body must not run when the sentinel write fails") }))
        XCTAssertEqual(try? Data(contentsOf: real), payload,
            "a sentinel-write failure must still restore the original byte-identical")
    }
}
