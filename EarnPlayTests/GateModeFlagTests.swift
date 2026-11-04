import Foundation
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #87 — gate mode flag: the child setup/gate composition follows
/// `SimulatedShieldMode` in the MAIN flow (not the demo view), so gate
/// scenarios can run on TestFlight via the on-device UserDefaults toggle.
///
/// - forced ⇒ the simulated pair (`SimulatedSetupAuthorizationService` +
///   `SimulatedShieldBackend`), with the honesty badge on;
/// - unforced ⇒ exactly the pre-#87 behavior (real FamilyControls
///   authorization + `NonEnforcingShieldBackend`).
///
/// The mode resolves once at composition (app launch): flipping the
/// toggle requires a restart. The resolver contract itself
/// (launch argument / environment / UserDefaults inputs) stays pinned by
/// `SimulatedShieldFlowTests.testSimulatedModeFlagResolution` in the
/// EarnPlayCore package; these tests pin the composition on top of it.
final class GateModeFlagTests: XCTestCase {
    @MainActor
    func testForcedModeUsesSimulatedPair() {
        let viewModel = SetupFlowViewModel.makeDefault(simulatedMode: true)

        XCTAssertTrue(
            viewModel.backend is SimulatedShieldBackend,
            "forced mode must install the simulated shield backend"
        )
        XCTAssertTrue(
            viewModel.authService is SimulatedSetupAuthorizationService,
            "forced mode must install the simulated authorization service"
        )
        XCTAssertTrue(viewModel.isSimulatedMode)
    }

    @MainActor
    func testUnforcedModeKeepsTodayBehavior() {
        let viewModel = SetupFlowViewModel.makeDefault(simulatedMode: false)

        XCTAssertTrue(
            viewModel.backend is NonEnforcingShieldBackend,
            "unforced mode must keep the non-enforcing backend (v1 builds the real one)"
        )
        XCTAssertTrue(
            viewModel.authService is FamilyControlsSetupAuthorizationService,
            "unforced mode must keep real FamilyControls authorization"
        )
        XCTAssertFalse(viewModel.isSimulatedMode)
    }

    @MainActor
    func testBareMakeDefaultFollowsLiveResolver() {
        // No ambient-state assumption: whatever the live resolver says
        // (launch argument, environment, or the UserDefaults toggle),
        // the bare composition must agree with it.
        let viewModel = SetupFlowViewModel.makeDefault()

        XCTAssertEqual(viewModel.isSimulatedMode, SimulatedShieldMode.isForced())
    }

    @MainActor
    func testInjectedAuthServiceStillWinsWhenUnforced() {
        // The Demo verification seam keeps its exact pre-#87 meaning:
        // an explicitly injected auth service is installed as-is, with
        // the non-enforcing backend, when the mode is unforced.
        let injected = SimulatedSetupAuthorizationService()
        let viewModel = SetupFlowViewModel.makeDefault(
            authService: injected,
            simulatedMode: false
        )

        XCTAssertTrue(viewModel.authService is SimulatedSetupAuthorizationService)
        XCTAssertTrue(viewModel.backend is NonEnforcingShieldBackend)
    }

    @MainActor
    func testSimulatedAuthInstallShowsBadgeEvenWithNonEnforcingBackend() {
        // Honesty: any simulated half (here simulated auth with the
        // non-enforcing backend, the injected Demo path) raises the
        // badge, so simulated approval never looks like real Screen
        // Time authorization.
        let viewModel = SetupFlowViewModel.makeDefault(
            authService: SimulatedSetupAuthorizationService(),
            simulatedMode: false
        )

        XCTAssertTrue(viewModel.isSimulatedMode)
    }
}
