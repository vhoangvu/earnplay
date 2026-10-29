import XCTest
import FamilyControls
@testable import EarnPlay

/// T2.3 fix round 1 — regression guard for the CI-SDK authorization mapping.
///
/// `FamilyControlsSetupAuthorizationService.map` must use ONLY
/// `AuthorizationStatus` cases present in the CI SDK (runner-default older
/// Xcode / pre-26.4 SDK: `.approved` / `.denied` / `.notDetermined`).
/// `.approvedWithDataAccess` (iOS 26.4+) does not exist there, so any
/// reference — even behind `#available` — fails CI compilation while staying
/// green on newer local toolchains. These tests pin the three SDK-available
/// mappings; keep them passing on every SDK, and never reintroduce a
/// newer-SDK-only member into the mapping.
final class SetupAuthorizationMappingTests: XCTestCase {
    func testApprovedMapsToApproved() {
        XCTAssertEqual(
            FamilyControlsSetupAuthorizationService.map(.approved),
            .approved
        )
    }

    func testDeniedMapsToDenied() {
        XCTAssertEqual(
            FamilyControlsSetupAuthorizationService.map(.denied),
            .denied
        )
    }

    func testNotDeterminedMapsToNotDetermined() {
        XCTAssertEqual(
            FamilyControlsSetupAuthorizationService.map(.notDetermined),
            .notDetermined
        )
    }

    /// T2.3 fix round 3 — the setup authorization request must target the
    /// guardian-approved child member: the parent (device organizer) grants
    /// FamilyControls authorization during setup, so `.individual` (device
    /// user self-approval) would bypass the parent-consent boundary.
    /// `FamilyControlsMember.child` is iOS 16.0 API, present in the CI SDK.
    func testRequestPathUsesGuardianApprovedChildMember() {
        XCTAssertEqual(
            FamilyControlsSetupAuthorizationService.requestedMembership,
            .child
        )
    }
}
