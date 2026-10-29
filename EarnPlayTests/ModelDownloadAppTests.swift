import XCTest
import EarnPlayCore

/// App-target coverage for issue #53 (simulator gate): the shipped
/// license attribution, the Application Support destination, and the
/// Wi-Fi-only configuration. All hermetic — no network is touched.
/// (Retry/progress behavior is covered against the same `ModelDownloader`
/// code in the package suite; this target pins what the app ships.)
final class ModelDownloadAppTests: XCTestCase {
    func testAboutAttributionNamesCommunityLicense() {
        XCTAssertTrue(ModelAttribution.llamaCommunityLicenseText.contains("Llama 3.2 Community License"),
            "the app must carry Llama 3.2 Community License attribution")
        XCTAssertTrue(ModelAttribution.llamaCommunityLicenseText.contains("Llama-3.2-1B-Instruct-GGUF"))
    }

    /// Fix round 2, finding 1 (§1.b.i(B)): the About screen's
    /// prominent label. The rendering inputs below (label + bundled
    /// texts) are bundle reads, so About renders them fully offline.
    func testAboutAttributionShowsBuiltWithLlamaLabel() {
        XCTAssertEqual(ModelAttribution.builtWithLlamaLabel, "Built with Llama")
    }

    /// Finding 1 (§1.b.i(A)): the license copy ships inside the app
    /// bundle and reads without network.
    func testAppBundleShipsLicenseCopyReadableOffline() {
        let text = ModelAttribution.bundledLicenseText()
        XCTAssertNotNil(text, "the license copy must ship in the app bundle")
        XCTAssertTrue(text?.contains("LLAMA 3.2 COMMUNITY LICENSE AGREEMENT") == true)
    }

    /// Finding 1 (§1.b.iii): the Notice file ships inside the app
    /// bundle carrying the exact required sentence.
    func testAppBundleShipsNoticeWithRequiredSentence() {
        let text = ModelAttribution.bundledNoticeText()
        XCTAssertNotNil(text, "the Notice file must ship in the app bundle")
        XCTAssertTrue(text?.contains(ModelAttribution.noticeAttributionSentence) == true)
    }

    func testDefaultDestinationIsApplicationSupportNotCaches() {
        let fileManager = FileManager.default
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        XCTAssertTrue(destination.path.hasPrefix(appSupport.path),
            "model must live in Application Support, got \(destination.path)")
        XCTAssertFalse(destination.path.hasPrefix(caches.path),
            "model must survive a Caches purge, got \(destination.path)")
    }

    func testLiveDownloaderIsWifiOnly() {
        XCTAssertFalse(URLSessionModelDownloadFetcher.wifiOnlyConfiguration().allowsCellularAccess,
            "the ~800 MB model must never download over cellular")
    }

    func testProductionDownloadPointsAtShippedModelFile() {
        let production = ModelDownloadConfiguration.production
        XCTAssertTrue(production.sourceURL.absoluteString.contains("bartowski/Llama-3.2-1B-Instruct-GGUF"))
        XCTAssertEqual(production.expectedByteCount, 807_694_464)
    }
}
