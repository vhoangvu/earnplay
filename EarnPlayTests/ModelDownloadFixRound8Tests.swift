import XCTest

/// Fix round 8 regression test (issue #53): when the deferred restore
/// move fails, the guard must RETAIN the shelter directory at its
/// reported path — it holds the only remaining copy of the pre-existing
/// file. Deleting it on the failure path destroys the original.
///
/// Hermetic: runs against a fake "real" file under temp (never the
/// actual default destination).
final class ModelDownloadFixRound8Tests: XCTestCase {
    private func makeFakeReal(payload: Data) throws -> (home: URL, real: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadFixRound8Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let real = home.appendingPathComponent("model.gguf")
        try payload.write(to: real)
        return (home, real)
    }

    /// A restore failure must leave the sheltered original intact at
    /// the reported backup path. The restore move is forced to throw
    /// by making the destination parent read-only; the guard's
    /// expected XCTFail on that path is absorbed by XCTExpectFailure
    /// so the retained-backup assertion is the verdict.
    func testRestoreFailureRetainsShelterBackup() throws {
        let guard_ = ShelteredFileGuard()
        let payload = Data("round8-pre-existing-model".utf8)
        let (home, real) = try makeFakeReal(payload: payload)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? FileManager.default.removeItem(at: home)
        }
        let sentinel = Data("round8-sentinel".utf8)
        var capturedBackup: URL?

        XCTExpectFailure("restore is forced to fail; the shelter backup must be retained for recovery") {
            try? guard_.run(real: real, sentinel: sentinel,
                write: { url, data in try data.write(to: url) },
                body: { backup in
                    capturedBackup = backup
                    // Force the deferred restore move to throw: a
                    // read-only parent rejects both the sentinel
                    // removal and the move destination.
                    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)
                })
        }

        let backupURL = try XCTUnwrap(capturedBackup, "a pre-existing file must have been sheltered")
        // Restore write access so cleanup succeeds.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
        XCTAssertEqual(try? Data(contentsOf: backupURL), payload,
            "a restore failure must retain the shelter backup at its reported path")
    }
}
