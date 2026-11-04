import XCTest
@testable import EarnPlayCore

/// Issue #93 fix (finding 5): the tutor factory's cheap registry
/// fallback — `activeBundleModelFileURL` resolves the persisted ACTIVE
/// bundle's model file with no hashing, no writes, and no retention,
/// so a retained snapshot stays usable when the default file is gone.
final class ActiveBundleModelURLTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ggufFile(in dir: URL, named name: String = "Model.gguf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("GGUF-fixture".utf8).write(to: url)
        return url
    }

    private func bundle(id: String, modelFilePath: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["bundleID": id, "modelVersion": "m", "promptVersion": "p"]
        if let modelFilePath { value["modelFilePath"] = modelFilePath }
        return value
    }

    private func writeStore(in dir: URL, activeBundleID: String,
                            bundles: [[String: Any]]) throws -> URL {
        let store = dir.appendingPathComponent("version-registry.json")
        let state: [String: Any] = ["bundles": bundles, "activeBundleID": activeBundleID]
        try JSONSerialization.data(withJSONObject: state).write(to: store)
        return store
    }

    func testResolvesActiveBundleAbsolutePath() throws {
        let dir = try tempDir()
        let model = try ggufFile(in: dir)
        let store = try writeStore(in: dir, activeBundleID: "previous-known-good",
                                   bundles: [bundle(id: "previous-known-good",
                                                    modelFilePath: model.path)])
        XCTAssertEqual(VersionRegistry.activeBundleModelFileURL(storeURL: store)?.path, model.path)
    }

    func testNilWhenStoreMissing() throws {
        let missing = try tempDir().appendingPathComponent("version-registry.json")
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: missing))
    }

    func testNilWhenStoreCorrupt() throws {
        let dir = try tempDir()
        let store = dir.appendingPathComponent("version-registry.json")
        try Data("not-json{".utf8).write(to: store)
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }

    func testNilWhenActiveBundleUnknown() throws {
        let dir = try tempDir()
        let model = try ggufFile(in: dir)
        let store = try writeStore(in: dir, activeBundleID: "no-such-bundle",
                                   bundles: [bundle(id: "current", modelFilePath: model.path)])
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }

    func testNilWhenActiveBundleBindsDefault() throws {
        let dir = try tempDir()
        let store = try writeStore(in: dir, activeBundleID: "current",
                                   bundles: [bundle(id: "current")])
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }

    func testNilWhenFileMissing() throws {
        let dir = try tempDir()
        let store = try writeStore(in: dir, activeBundleID: "previous-known-good",
                                   bundles: [bundle(id: "previous-known-good",
                                                    modelFilePath: dir.appendingPathComponent("Gone.gguf").path)])
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }

    func testNilWhenFileNotGGUF() throws {
        let dir = try tempDir()
        let impostor = dir.appendingPathComponent("Impostor.gguf")
        try Data("NOT-A-MODEL".utf8).write(to: impostor)
        let store = try writeStore(in: dir, activeBundleID: "previous-known-good",
                                   bundles: [bundle(id: "previous-known-good",
                                                    modelFilePath: impostor.path)])
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }

    func testNilWhenPathIsDirectory() throws {
        let dir = try tempDir()
        let store = try writeStore(in: dir, activeBundleID: "previous-known-good",
                                   bundles: [bundle(id: "previous-known-good",
                                                    modelFilePath: dir.path)])
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }

    func testResolvesRelativePathAgainstRegistryDirectory() throws {
        let dir = try tempDir()
        let model = try ggufFile(in: dir, named: "previous-known-good-model-1.gguf")
        let store = try writeStore(in: dir, activeBundleID: "previous-known-good",
                                   bundles: [bundle(id: "previous-known-good",
                                                    modelFilePath: model.lastPathComponent)])
        XCTAssertEqual(VersionRegistry.activeBundleModelFileURL(storeURL: store)?.path, model.path)
    }

    func testMigratesAbsolutePathByBasename() throws {
        // Restored-container parity with the reload path: the stored
        // absolute path is gone, but the same basename sits beside the
        // registry store.
        let dir = try tempDir()
        let model = try ggufFile(in: dir, named: "previous-known-good-model-2.gguf")
        let store = try writeStore(in: dir, activeBundleID: "previous-known-good",
                                   bundles: [bundle(id: "previous-known-good",
                                                    modelFilePath: "/old/container/\(model.lastPathComponent)")])
        XCTAssertEqual(VersionRegistry.activeBundleModelFileURL(storeURL: store)?.path, model.path)
    }

    func testIgnoresNonActiveBundles() throws {
        let dir = try tempDir()
        let model = try ggufFile(in: dir)
        let store = try writeStore(
            in: dir, activeBundleID: "current",
            bundles: [bundle(id: "current"),
                      bundle(id: "previous-known-good", modelFilePath: model.path)])
        XCTAssertNil(VersionRegistry.activeBundleModelFileURL(storeURL: store))
    }
}
